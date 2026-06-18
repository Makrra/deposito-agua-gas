-- ============================================================
-- SETUP SISTEMA DEPÓSITO DE ÁGUA - Garrafão 20L
-- Execute no SQL Editor do Supabase Dashboard (projeto novo)
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ------------------------------------------------------------
-- 1. USUARIOS (perfil ligado a auth.users, define role)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS usuarios (
  id        UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  nome      TEXT NOT NULL,
  role      TEXT NOT NULL DEFAULT 'caixa' CHECK (role IN ('administrador','caixa','entregador')),
  telefone  TEXT,
  ativo     BOOLEAN NOT NULL DEFAULT true,
  criado_em TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Função auxiliar (SECURITY DEFINER) para ler o role do usuário logado
-- sem disparar recursão de RLS na própria tabela usuarios.
CREATE OR REPLACE FUNCTION public.current_role()
RETURNS TEXT
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT role FROM public.usuarios WHERE id = auth.uid();
$$;

-- ------------------------------------------------------------
-- 2. CONFIGURACOES (chave/valor genérico)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS configuracoes (
  chave TEXT PRIMARY KEY,
  valor TEXT
);

-- ------------------------------------------------------------
-- 3. MARCAS (marca de água ou de gás, preço de venda atual)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS marcas (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  nome              TEXT NOT NULL UNIQUE,
  tipo              TEXT NOT NULL DEFAULT 'agua' CHECK (tipo IN ('agua','gas')),
  preco_venda_atual NUMERIC(10,2) NOT NULL DEFAULT 0,
  ativo             BOOLEAN NOT NULL DEFAULT true,
  criado_em         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ------------------------------------------------------------
-- 4. LOTES_GARRAFAO (lote = uma entrega: marca + ano de validade + data
-- de chegada; várias entregas da mesma marca/ano em dias diferentes
-- geram lotes/cards separados, por isso não há unique em marca+ano)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lotes_garrafao (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  marca_id     UUID NOT NULL REFERENCES marcas(id) ON DELETE RESTRICT,
  ano_validade INTEGER NOT NULL CHECK (ano_validade BETWEEN 2000 AND 2100),
  data_chegada DATE NOT NULL DEFAULT CURRENT_DATE,
  qtd_cheios   INTEGER NOT NULL DEFAULT 0 CHECK (qtd_cheios >= 0),
  qtd_vazios   INTEGER NOT NULL DEFAULT 0 CHECK (qtd_vazios >= 0),
  status       TEXT NOT NULL DEFAULT 'ativo' CHECK (status IN ('ativo','esgotado','vencido','descontinuado')),
  observacao   TEXT,
  criado_em    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_lotes_marca        ON lotes_garrafao(marca_id);
CREATE INDEX IF NOT EXISTS idx_lotes_ano_validade ON lotes_garrafao(ano_validade);
CREATE INDEX IF NOT EXISTS idx_lotes_data_chegada ON lotes_garrafao(data_chegada);
CREATE INDEX IF NOT EXISTS idx_lotes_status       ON lotes_garrafao(status);

-- ------------------------------------------------------------
-- 4b. ESTOQUE_GAS (gás não tem validade nem lote por data — é só um
-- contador de cheios/vazios por marca de gás)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS estoque_gas (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  marca_id   UUID NOT NULL UNIQUE REFERENCES marcas(id) ON DELETE CASCADE,
  qtd_cheios INTEGER NOT NULL DEFAULT 0 CHECK (qtd_cheios >= 0),
  qtd_vazios INTEGER NOT NULL DEFAULT 0 CHECK (qtd_vazios >= 0),
  criado_em  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_estoque_gas_marca ON estoque_gas(marca_id);

-- ------------------------------------------------------------
-- 5. CLIENTES
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS clientes (
  id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tipo                     TEXT NOT NULL DEFAULT 'pf' CHECK (tipo IN ('pf','pj')),
  nome                     TEXT NOT NULL,
  telefone                 TEXT,
  endereco                 TEXT,
  saldo_fiado              NUMERIC(10,2) NOT NULL DEFAULT 0,
  limite_fiado             NUMERIC(10,2) NOT NULL DEFAULT 0,
  saldo_comodato_garrafoes INTEGER NOT NULL DEFAULT 0 CHECK (saldo_comodato_garrafoes >= 0),
  ativo                    BOOLEAN NOT NULL DEFAULT true,
  observacao               TEXT,
  criado_em                TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_clientes_nome  ON clientes(nome);
CREATE INDEX IF NOT EXISTS idx_clientes_saldo ON clientes(saldo_fiado) WHERE saldo_fiado > 0;

-- ------------------------------------------------------------
-- 6. PEDIDOS (cabeçalho da venda/entrega)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pedidos (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cliente_id      UUID NOT NULL REFERENCES clientes(id) ON DELETE RESTRICT,
  data            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  forma_pagamento TEXT NOT NULL CHECK (forma_pagamento IN ('dinheiro','pix','fiado')),
  status          TEXT NOT NULL DEFAULT 'aberto' CHECK (status IN ('aberto','concluido','cancelado')),
  total           NUMERIC(10,2) NOT NULL DEFAULT 0,
  entregador_id   UUID REFERENCES usuarios(id),
  status_entrega  TEXT NOT NULL DEFAULT 'pendente' CHECK (status_entrega IN ('pendente','entregue','cancelada')),
  data_entrega    TIMESTAMPTZ,
  observacao      TEXT,
  criado_por      UUID REFERENCES usuarios(id),
  criado_em       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_pedidos_cliente       ON pedidos(cliente_id);
CREATE INDEX IF NOT EXISTS idx_pedidos_entregador     ON pedidos(entregador_id);
CREATE INDEX IF NOT EXISTS idx_pedidos_status_entrega ON pedidos(status_entrega);
CREATE INDEX IF NOT EXISTS idx_pedidos_data           ON pedidos(data);

-- ------------------------------------------------------------
-- 7. ITENS_PEDIDO (lote_id é NULL para itens de gás, que não têm lote;
-- nesse caso o estoque é resolvido por marca_id em estoque_gas)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS itens_pedido (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pedido_id      UUID NOT NULL REFERENCES pedidos(id) ON DELETE CASCADE,
  lote_id        UUID REFERENCES lotes_garrafao(id) ON DELETE RESTRICT,
  marca_id       UUID NOT NULL REFERENCES marcas(id) ON DELETE RESTRICT,
  quantidade     INTEGER NOT NULL CHECK (quantidade > 0),
  preco_unitario NUMERIC(10,2) NOT NULL,
  tipo_vasilhame TEXT NOT NULL DEFAULT 'troca' CHECK (tipo_vasilhame IN ('troca','venda','comodato')),
  preco_vasilhame NUMERIC(10,2) NOT NULL DEFAULT 0,
  criado_em      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_itens_pedido_pedido ON itens_pedido(pedido_id);
CREATE INDEX IF NOT EXISTS idx_itens_pedido_lote   ON itens_pedido(lote_id);

-- ------------------------------------------------------------
-- 8. MOVIMENTOS_ESTOQUE (ledger append-only)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS movimentos_estoque (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  lote_id              UUID NOT NULL REFERENCES lotes_garrafao(id) ON DELETE RESTRICT,
  tipo                 TEXT NOT NULL CHECK (tipo IN ('entrada_fabrica','saida_venda','retorno_vazio','avaria','ajuste')),
  quantidade           INTEGER NOT NULL,
  referencia_pedido_id UUID REFERENCES pedidos(id),
  observacao           TEXT,
  data                 TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  criado_por           UUID REFERENCES usuarios(id)
);

CREATE INDEX IF NOT EXISTS idx_mov_estoque_lote ON movimentos_estoque(lote_id);
CREATE INDEX IF NOT EXISTS idx_mov_estoque_data ON movimentos_estoque(data);

-- ------------------------------------------------------------
-- 9. AVARIAS
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS avarias (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  lote_id    UUID NOT NULL REFERENCES lotes_garrafao(id) ON DELETE RESTRICT,
  tipo       TEXT NOT NULL DEFAULT 'cheio' CHECK (tipo IN ('cheio','vazio')),
  quantidade INTEGER NOT NULL CHECK (quantidade > 0),
  motivo     TEXT,
  data       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  criado_por UUID REFERENCES usuarios(id)
);

CREATE INDEX IF NOT EXISTS idx_avarias_lote ON avarias(lote_id);

-- ------------------------------------------------------------
-- 10. PAGAMENTOS_FIADO (abate saldo_fiado do cliente)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pagamentos_fiado (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cliente_id UUID NOT NULL REFERENCES clientes(id) ON DELETE CASCADE,
  pedido_id  UUID REFERENCES pedidos(id) ON DELETE SET NULL, -- pagamento pode ser vinculado a um pedido específico (confirmação de pagamento)
  valor      NUMERIC(10,2) NOT NULL CHECK (valor > 0),
  forma      TEXT NOT NULL DEFAULT 'dinheiro' CHECK (forma IN ('dinheiro','pix')),
  data       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  observacao TEXT,
  criado_por UUID REFERENCES usuarios(id)
);

CREATE INDEX IF NOT EXISTS idx_pag_fiado_cliente ON pagamentos_fiado(cliente_id);
CREATE INDEX IF NOT EXISTS idx_pag_fiado_pedido  ON pagamentos_fiado(pedido_id);

-- ------------------------------------------------------------
-- 11. DEVOLUCOES_COMODATO (abate saldo_comodato_garrafoes do cliente)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS devolucoes_comodato (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cliente_id UUID NOT NULL REFERENCES clientes(id) ON DELETE CASCADE,
  lote_id    UUID NOT NULL REFERENCES lotes_garrafao(id) ON DELETE RESTRICT,
  quantidade INTEGER NOT NULL CHECK (quantidade > 0),
  data       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  criado_por UUID REFERENCES usuarios(id)
);

CREATE INDEX IF NOT EXISTS idx_devolucoes_cliente ON devolucoes_comodato(cliente_id);

-- ------------------------------------------------------------
-- 12. DESCONTOS_CLIENTE (desconto por cliente, opcionalmente por marca)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS descontos_cliente (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cliente_id UUID NOT NULL REFERENCES clientes(id) ON DELETE CASCADE,
  marca_id   UUID REFERENCES marcas(id) ON DELETE CASCADE, -- NULL = desconto vale para qualquer marca
  tipo       TEXT NOT NULL CHECK (tipo IN ('reais','porcentagem')),
  valor      NUMERIC(10,2) NOT NULL CHECK (valor > 0),
  criado_em  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_desconto_cliente_marca UNIQUE (cliente_id, marca_id)
);

CREATE INDEX IF NOT EXISTS idx_descontos_cliente ON descontos_cliente(cliente_id);

-- ------------------------------------------------------------
-- 13. VIEWS
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW vw_caixa_dia WITH (security_invoker = true) AS
SELECT
  date_trunc('day', data) AS dia,
  forma_pagamento,
  COUNT(*)   AS qtd_pedidos,
  SUM(total) AS total
FROM pedidos
WHERE status = 'concluido' AND forma_pagamento IN ('dinheiro','pix')
GROUP BY date_trunc('day', data), forma_pagamento;

CREATE OR REPLACE VIEW vw_entregas_dia WITH (security_invoker = true) AS
SELECT
  p.id, p.entregador_id, p.status_entrega, p.data, p.data_entrega, p.total, p.forma_pagamento,
  c.nome AS cliente_nome, c.telefone AS cliente_telefone, c.endereco AS cliente_endereco
FROM pedidos p
JOIN clientes c ON c.id = p.cliente_id
WHERE p.status != 'cancelado';

-- ============================================================
-- TRIGGERS DE GUARDA DE COLUNA (RLS não restringe coluna em UPDATE)
-- ============================================================

-- entregador só pode alterar status_entrega/data_entrega em pedidos
CREATE OR REPLACE FUNCTION public.guard_pedidos_entregador()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF public.current_role() = 'entregador' THEN
    IF NEW.cliente_id      IS DISTINCT FROM OLD.cliente_id
       OR NEW.total           IS DISTINCT FROM OLD.total
       OR NEW.forma_pagamento IS DISTINCT FROM OLD.forma_pagamento
       OR NEW.status           IS DISTINCT FROM OLD.status
       OR NEW.entregador_id   IS DISTINCT FROM OLD.entregador_id THEN
      RAISE EXCEPTION 'entregador só pode alterar status_entrega e data_entrega';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_pedidos_entregador ON pedidos;
CREATE TRIGGER trg_guard_pedidos_entregador
  BEFORE UPDATE ON pedidos
  FOR EACH ROW EXECUTE FUNCTION public.guard_pedidos_entregador();

-- caixa não pode alterar limite_fiado de clientes
CREATE OR REPLACE FUNCTION public.guard_clientes_caixa()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF public.current_role() = 'caixa' AND NEW.limite_fiado IS DISTINCT FROM OLD.limite_fiado THEN
    RAISE EXCEPTION 'caixa não pode alterar o limite de fiado do cliente';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_clientes_caixa ON clientes;
CREATE TRIGGER trg_guard_clientes_caixa
  BEFORE UPDATE ON clientes
  FOR EACH ROW EXECUTE FUNCTION public.guard_clientes_caixa();

-- ============================================================
-- RLS POLICIES
-- ============================================================
ALTER TABLE usuarios            ENABLE ROW LEVEL SECURITY;
ALTER TABLE configuracoes       ENABLE ROW LEVEL SECURITY;
ALTER TABLE marcas              ENABLE ROW LEVEL SECURITY;
ALTER TABLE lotes_garrafao      ENABLE ROW LEVEL SECURITY;
ALTER TABLE estoque_gas         ENABLE ROW LEVEL SECURITY;
ALTER TABLE clientes            ENABLE ROW LEVEL SECURITY;
ALTER TABLE pedidos             ENABLE ROW LEVEL SECURITY;
ALTER TABLE itens_pedido        ENABLE ROW LEVEL SECURITY;
ALTER TABLE movimentos_estoque  ENABLE ROW LEVEL SECURITY;
ALTER TABLE avarias             ENABLE ROW LEVEL SECURITY;
ALTER TABLE pagamentos_fiado    ENABLE ROW LEVEL SECURITY;
ALTER TABLE devolucoes_comodato ENABLE ROW LEVEL SECURITY;
ALTER TABLE descontos_cliente   ENABLE ROW LEVEL SECURITY;

-- usuarios: qualquer autenticado lê a própria linha (p/ saber seu role);
-- administrador e caixa leem todas as linhas (caixa precisa listar
-- entregadores pra atribuir pedidos); só administrador gerencia (write).
DROP POLICY IF EXISTS "usuarios_select_self_or_admin" ON usuarios;
CREATE POLICY "usuarios_select_self_or_admin" ON usuarios FOR SELECT
  USING (id = auth.uid() OR public.current_role() IN ('administrador','caixa'));

DROP POLICY IF EXISTS "usuarios_insert_admin" ON usuarios;
CREATE POLICY "usuarios_insert_admin" ON usuarios FOR INSERT
  WITH CHECK (public.current_role() = 'administrador');

DROP POLICY IF EXISTS "usuarios_update_admin" ON usuarios;
CREATE POLICY "usuarios_update_admin" ON usuarios FOR UPDATE
  USING (public.current_role() = 'administrador') WITH CHECK (public.current_role() = 'administrador');

-- configuracoes: leitura para qualquer logado (administrador/caixa usam o
-- preco_vasilhame_avulso); escrita só administrador.
DROP POLICY IF EXISTS "configuracoes_select_auth" ON configuracoes;
CREATE POLICY "configuracoes_select_auth" ON configuracoes FOR SELECT
  USING (auth.role() = 'authenticated');

DROP POLICY IF EXISTS "configuracoes_write_admin" ON configuracoes;
CREATE POLICY "configuracoes_write_admin" ON configuracoes FOR ALL
  USING (public.current_role() = 'administrador') WITH CHECK (public.current_role() = 'administrador');

-- marcas: leitura para qualquer autenticado (entregador também precisa ver
-- nome da marca nos itens da entrega); escrita só administrador.
DROP POLICY IF EXISTS "marcas_select_admin_caixa" ON marcas;
DROP POLICY IF EXISTS "marcas_select_auth" ON marcas;
CREATE POLICY "marcas_select_auth" ON marcas FOR SELECT
  USING (auth.role() = 'authenticated');

DROP POLICY IF EXISTS "marcas_write_admin" ON marcas;
CREATE POLICY "marcas_write_admin" ON marcas FOR INSERT
  WITH CHECK (public.current_role() = 'administrador');
DROP POLICY IF EXISTS "marcas_update_admin" ON marcas;
CREATE POLICY "marcas_update_admin" ON marcas FOR UPDATE
  USING (public.current_role() = 'administrador') WITH CHECK (public.current_role() = 'administrador');
DROP POLICY IF EXISTS "marcas_delete_admin" ON marcas;
CREATE POLICY "marcas_delete_admin" ON marcas FOR DELETE
  USING (public.current_role() = 'administrador');

-- lotes_garrafao, estoque_gas, movimentos_estoque, avarias: administrador e caixa operam tudo.
DROP POLICY IF EXISTS "lotes_admin_caixa_all" ON lotes_garrafao;
CREATE POLICY "lotes_admin_caixa_all" ON lotes_garrafao FOR ALL
  USING (public.current_role() IN ('administrador','caixa'))
  WITH CHECK (public.current_role() IN ('administrador','caixa'));

DROP POLICY IF EXISTS "estoque_gas_admin_caixa_all" ON estoque_gas;
CREATE POLICY "estoque_gas_admin_caixa_all" ON estoque_gas FOR ALL
  USING (public.current_role() IN ('administrador','caixa'))
  WITH CHECK (public.current_role() IN ('administrador','caixa'));

DROP POLICY IF EXISTS "movimentos_admin_caixa_all" ON movimentos_estoque;
CREATE POLICY "movimentos_admin_caixa_all" ON movimentos_estoque FOR ALL
  USING (public.current_role() IN ('administrador','caixa'))
  WITH CHECK (public.current_role() IN ('administrador','caixa'));

DROP POLICY IF EXISTS "avarias_admin_caixa_all" ON avarias;
CREATE POLICY "avarias_admin_caixa_all" ON avarias FOR ALL
  USING (public.current_role() IN ('administrador','caixa'))
  WITH CHECK (public.current_role() IN ('administrador','caixa'));

DROP POLICY IF EXISTS "pagamentos_fiado_admin_caixa_all" ON pagamentos_fiado;
CREATE POLICY "pagamentos_fiado_admin_caixa_all" ON pagamentos_fiado FOR ALL
  USING (public.current_role() IN ('administrador','caixa'))
  WITH CHECK (public.current_role() IN ('administrador','caixa'));

-- devolucoes_comodato: administrador e caixa podem ver/criar/editar, mas
-- só administrador pode excluir uma transação (correção de erro).
DROP POLICY IF EXISTS "devolucoes_admin_caixa_all" ON devolucoes_comodato;
DROP POLICY IF EXISTS "devolucoes_select_admin_caixa" ON devolucoes_comodato;
CREATE POLICY "devolucoes_select_admin_caixa" ON devolucoes_comodato FOR SELECT
  USING (public.current_role() IN ('administrador','caixa'));
DROP POLICY IF EXISTS "devolucoes_insert_admin_caixa" ON devolucoes_comodato;
CREATE POLICY "devolucoes_insert_admin_caixa" ON devolucoes_comodato FOR INSERT
  WITH CHECK (public.current_role() IN ('administrador','caixa'));
DROP POLICY IF EXISTS "devolucoes_update_admin_caixa" ON devolucoes_comodato;
CREATE POLICY "devolucoes_update_admin_caixa" ON devolucoes_comodato FOR UPDATE
  USING (public.current_role() IN ('administrador','caixa')) WITH CHECK (public.current_role() IN ('administrador','caixa'));
DROP POLICY IF EXISTS "devolucoes_delete_admin" ON devolucoes_comodato;
CREATE POLICY "devolucoes_delete_admin" ON devolucoes_comodato FOR DELETE
  USING (public.current_role() = 'administrador');

-- descontos_cliente: administrador e caixa podem ver (precisam saber o
-- desconto pra aplicar num pedido), mas só administrador cria/edita/remove
-- (é uma decisão de preço, igual à restrição de preço de marca).
DROP POLICY IF EXISTS "descontos_select_admin_caixa" ON descontos_cliente;
CREATE POLICY "descontos_select_admin_caixa" ON descontos_cliente FOR SELECT
  USING (public.current_role() IN ('administrador','caixa'));

DROP POLICY IF EXISTS "descontos_insert_admin" ON descontos_cliente;
CREATE POLICY "descontos_insert_admin" ON descontos_cliente FOR INSERT
  WITH CHECK (public.current_role() = 'administrador');
DROP POLICY IF EXISTS "descontos_update_admin" ON descontos_cliente;
CREATE POLICY "descontos_update_admin" ON descontos_cliente FOR UPDATE
  USING (public.current_role() = 'administrador') WITH CHECK (public.current_role() = 'administrador');
DROP POLICY IF EXISTS "descontos_delete_admin" ON descontos_cliente;
CREATE POLICY "descontos_delete_admin" ON descontos_cliente FOR DELETE
  USING (public.current_role() = 'administrador');

-- clientes: administrador/caixa podem ver/criar/editar (limite_fiado é
-- protegido por trigger, não por RLS); só administrador pode excluir um
-- cliente; entregador só vê clientes de entregas do dia atribuídas a ele.
DROP POLICY IF EXISTS "clientes_admin_caixa_all" ON clientes;
DROP POLICY IF EXISTS "clientes_select_admin_caixa" ON clientes;
CREATE POLICY "clientes_select_admin_caixa" ON clientes FOR SELECT
  USING (public.current_role() IN ('administrador','caixa'));
DROP POLICY IF EXISTS "clientes_insert_admin_caixa" ON clientes;
CREATE POLICY "clientes_insert_admin_caixa" ON clientes FOR INSERT
  WITH CHECK (public.current_role() IN ('administrador','caixa'));
DROP POLICY IF EXISTS "clientes_update_admin_caixa" ON clientes;
CREATE POLICY "clientes_update_admin_caixa" ON clientes FOR UPDATE
  USING (public.current_role() IN ('administrador','caixa')) WITH CHECK (public.current_role() IN ('administrador','caixa'));
DROP POLICY IF EXISTS "clientes_delete_admin" ON clientes;
CREATE POLICY "clientes_delete_admin" ON clientes FOR DELETE
  USING (public.current_role() = 'administrador');

DROP POLICY IF EXISTS "clientes_entregador_select" ON clientes;
CREATE POLICY "clientes_entregador_select" ON clientes FOR SELECT
  USING (
    public.current_role() = 'entregador'
    AND EXISTS (
      SELECT 1 FROM pedidos p
      WHERE p.cliente_id = clientes.id
        AND p.entregador_id = auth.uid()
        AND p.data::date = CURRENT_DATE
    )
  );

-- pedidos: administrador/caixa têm acesso total. entregador só vê e só
-- atualiza (via trigger de guarda) os pedidos do dia atribuídos a ele.
DROP POLICY IF EXISTS "pedidos_admin_caixa_all" ON pedidos;
CREATE POLICY "pedidos_admin_caixa_all" ON pedidos FOR ALL
  USING (public.current_role() IN ('administrador','caixa'))
  WITH CHECK (public.current_role() IN ('administrador','caixa'));

DROP POLICY IF EXISTS "pedidos_entregador_select" ON pedidos;
CREATE POLICY "pedidos_entregador_select" ON pedidos FOR SELECT
  USING (
    public.current_role() = 'entregador'
    AND entregador_id = auth.uid()
    AND data::date = CURRENT_DATE
  );

DROP POLICY IF EXISTS "pedidos_entregador_update" ON pedidos;
CREATE POLICY "pedidos_entregador_update" ON pedidos FOR UPDATE
  USING (
    public.current_role() = 'entregador'
    AND entregador_id = auth.uid()
    AND data::date = CURRENT_DATE
  )
  WITH CHECK (
    public.current_role() = 'entregador'
    AND entregador_id = auth.uid()
    AND data::date = CURRENT_DATE
  );

-- itens_pedido: administrador/caixa têm acesso total; entregador só lê os
-- itens dos pedidos visíveis a ele (para saber o que entregar).
DROP POLICY IF EXISTS "itens_pedido_admin_caixa_all" ON itens_pedido;
CREATE POLICY "itens_pedido_admin_caixa_all" ON itens_pedido FOR ALL
  USING (public.current_role() IN ('administrador','caixa'))
  WITH CHECK (public.current_role() IN ('administrador','caixa'));

DROP POLICY IF EXISTS "itens_pedido_entregador_select" ON itens_pedido;
CREATE POLICY "itens_pedido_entregador_select" ON itens_pedido FOR SELECT
  USING (
    public.current_role() = 'entregador'
    AND EXISTS (
      SELECT 1 FROM pedidos p
      WHERE p.id = itens_pedido.pedido_id
        AND p.entregador_id = auth.uid()
        AND p.data::date = CURRENT_DATE
    )
  );

-- ============================================================
-- SEED INICIAL
-- ============================================================
INSERT INTO configuracoes (chave, valor)
VALUES ('preco_vasilhame_avulso', '15.00')
ON CONFLICT (chave) DO NOTHING;

INSERT INTO configuracoes (chave, valor)
VALUES ('empresa_nome', 'Depósito de Água')
ON CONFLICT (chave) DO NOTHING;

-- ============================================================
-- MIGRAÇÃO (rodar só se você já executou este script antes da
-- Fase 3, quando a tabela avarias ainda não tinha a coluna "tipo")
-- ============================================================
-- ALTER TABLE avarias ADD COLUMN IF NOT EXISTS tipo TEXT NOT NULL DEFAULT 'cheio' CHECK (tipo IN ('cheio','vazio'));

-- ============================================================
-- MIGRAÇÃO (rodar só se você já tinha criado lotes_garrafao com
-- data_fabricacao/data_validade, antes do ajuste pra "só o ano")
-- ============================================================
-- ALTER TABLE lotes_garrafao DROP CONSTRAINT IF EXISTS uq_lote;
-- ALTER TABLE lotes_garrafao DROP COLUMN IF EXISTS data_validade;
-- ALTER TABLE lotes_garrafao ADD COLUMN IF NOT EXISTS ano_validade INTEGER CHECK (ano_validade BETWEEN 2000 AND 2100);
-- UPDATE lotes_garrafao SET ano_validade = EXTRACT(YEAR FROM (data_fabricacao + INTERVAL '3 years'))::int WHERE ano_validade IS NULL;
-- ALTER TABLE lotes_garrafao ALTER COLUMN ano_validade SET NOT NULL;
-- ALTER TABLE lotes_garrafao DROP COLUMN IF EXISTS data_fabricacao;
-- ALTER TABLE lotes_garrafao ADD CONSTRAINT uq_lote UNIQUE (marca_id, ano_validade);
-- DROP INDEX IF EXISTS idx_lotes_validade;
-- CREATE INDEX IF NOT EXISTS idx_lotes_ano_validade ON lotes_garrafao(ano_validade);

-- ============================================================
-- MIGRAÇÃO (rodar só se você já executou este script antes da
-- tabela descontos_cliente existir)
-- ============================================================
-- CREATE TABLE IF NOT EXISTS descontos_cliente (
--   id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
--   cliente_id UUID NOT NULL REFERENCES clientes(id) ON DELETE CASCADE,
--   marca_id   UUID REFERENCES marcas(id) ON DELETE CASCADE,
--   tipo       TEXT NOT NULL CHECK (tipo IN ('reais','porcentagem')),
--   valor      NUMERIC(10,2) NOT NULL CHECK (valor > 0),
--   criado_em  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
--   CONSTRAINT uq_desconto_cliente_marca UNIQUE (cliente_id, marca_id)
-- );
-- CREATE INDEX IF NOT EXISTS idx_descontos_cliente ON descontos_cliente(cliente_id);
-- ALTER TABLE descontos_cliente ENABLE ROW LEVEL SECURITY;
-- (rode também os CREATE POLICY de descontos_cliente listados acima na seção RLS)

-- ============================================================
-- MIGRAÇÃO (rodar só se você já tinha criado lotes_garrafao antes
-- da coluna data_chegada e da remoção do unique marca+ano)
-- ============================================================
-- ALTER TABLE lotes_garrafao DROP CONSTRAINT IF EXISTS uq_lote;
-- ALTER TABLE lotes_garrafao ADD COLUMN IF NOT EXISTS data_chegada DATE NOT NULL DEFAULT CURRENT_DATE;
-- CREATE INDEX IF NOT EXISTS idx_lotes_data_chegada ON lotes_garrafao(data_chegada);

-- ============================================================
-- MIGRAÇÃO (rodar só se a policy de devolucoes_comodato ainda for a
-- antiga "devolucoes_admin_caixa_all" FOR ALL — restringe DELETE ao
-- administrador)
-- ============================================================
-- DROP POLICY IF EXISTS "devolucoes_admin_caixa_all" ON devolucoes_comodato;
-- CREATE POLICY "devolucoes_select_admin_caixa" ON devolucoes_comodato FOR SELECT
--   USING (public.current_role() IN ('administrador','caixa'));
-- CREATE POLICY "devolucoes_insert_admin_caixa" ON devolucoes_comodato FOR INSERT
--   WITH CHECK (public.current_role() IN ('administrador','caixa'));
-- CREATE POLICY "devolucoes_update_admin_caixa" ON devolucoes_comodato FOR UPDATE
--   USING (public.current_role() IN ('administrador','caixa')) WITH CHECK (public.current_role() IN ('administrador','caixa'));
-- CREATE POLICY "devolucoes_delete_admin" ON devolucoes_comodato FOR DELETE
--   USING (public.current_role() = 'administrador');

-- ============================================================
-- MIGRAÇÃO: permitir excluir cliente (admin) e arrastar pagamentos/
-- devoluções de comodato junto (cascade), em vez de bloquear a exclusão
-- ============================================================
-- ALTER TABLE pagamentos_fiado DROP CONSTRAINT IF EXISTS pagamentos_fiado_cliente_id_fkey;
-- ALTER TABLE pagamentos_fiado ADD CONSTRAINT pagamentos_fiado_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES clientes(id) ON DELETE CASCADE;
-- ALTER TABLE devolucoes_comodato DROP CONSTRAINT IF EXISTS devolucoes_comodato_cliente_id_fkey;
-- ALTER TABLE devolucoes_comodato ADD CONSTRAINT devolucoes_comodato_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES clientes(id) ON DELETE CASCADE;
--
-- DROP POLICY IF EXISTS "clientes_admin_caixa_all" ON clientes;
-- CREATE POLICY "clientes_select_admin_caixa" ON clientes FOR SELECT
--   USING (public.current_role() IN ('administrador','caixa'));
-- CREATE POLICY "clientes_insert_admin_caixa" ON clientes FOR INSERT
--   WITH CHECK (public.current_role() IN ('administrador','caixa'));
-- CREATE POLICY "clientes_update_admin_caixa" ON clientes FOR UPDATE
--   USING (public.current_role() IN ('administrador','caixa')) WITH CHECK (public.current_role() IN ('administrador','caixa'));
-- CREATE POLICY "clientes_delete_admin" ON clientes FOR DELETE
--   USING (public.current_role() = 'administrador');

-- ============================================================
-- MIGRAÇÃO: suporte a venda de gás (marcas.tipo + estoque_gas)
-- ============================================================
-- ALTER TABLE marcas ADD COLUMN IF NOT EXISTS tipo TEXT NOT NULL DEFAULT 'agua' CHECK (tipo IN ('agua','gas'));
--
-- CREATE TABLE IF NOT EXISTS estoque_gas (
--   id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
--   marca_id   UUID NOT NULL UNIQUE REFERENCES marcas(id) ON DELETE CASCADE,
--   qtd_cheios INTEGER NOT NULL DEFAULT 0 CHECK (qtd_cheios >= 0),
--   qtd_vazios INTEGER NOT NULL DEFAULT 0 CHECK (qtd_vazios >= 0),
--   criado_em  TIMESTAMPTZ NOT NULL DEFAULT NOW()
-- );
-- CREATE INDEX IF NOT EXISTS idx_estoque_gas_marca ON estoque_gas(marca_id);
-- ALTER TABLE estoque_gas ENABLE ROW LEVEL SECURITY;
-- CREATE POLICY "estoque_gas_admin_caixa_all" ON estoque_gas FOR ALL
--   USING (public.current_role() IN ('administrador','caixa'))
--   WITH CHECK (public.current_role() IN ('administrador','caixa'));

-- ============================================================
-- MIGRAÇÃO (Fase 4): itens de gás não têm lote, e pagamento pode ser
-- vinculado a um pedido específico (confirmação de pagamento)
-- ============================================================
-- ALTER TABLE itens_pedido ALTER COLUMN lote_id DROP NOT NULL;
-- ALTER TABLE pagamentos_fiado ADD COLUMN IF NOT EXISTS pedido_id UUID REFERENCES pedidos(id) ON DELETE SET NULL;
-- CREATE INDEX IF NOT EXISTS idx_pag_fiado_pedido ON pagamentos_fiado(pedido_id);
--
-- DROP POLICY IF EXISTS "usuarios_select_self_or_admin" ON usuarios;
-- CREATE POLICY "usuarios_select_self_or_admin" ON usuarios FOR SELECT
--   USING (id = auth.uid() OR public.current_role() IN ('administrador','caixa'));
--
-- DROP POLICY IF EXISTS "marcas_select_admin_caixa" ON marcas;
-- DROP POLICY IF EXISTS "marcas_select_auth" ON marcas;
-- CREATE POLICY "marcas_select_auth" ON marcas FOR SELECT
--   USING (auth.role() = 'authenticated');

-- Após rodar este script, crie o primeiro usuário em:
-- Authentication > Users > Add user (email + senha)
-- e depois rode (substituindo o UUID pelo id do usuário criado):
--
-- INSERT INTO usuarios (id, nome, role) VALUES ('<uuid-do-usuario>', 'Seu Nome', 'administrador');
