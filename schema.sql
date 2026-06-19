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
-- 4. LOTES_GARRAFAO (cheios apenas — um registro por marca + ano de
-- validade, que só acumula; cada chegada de carregamento é uma
-- transação em movimentos_estoque, não um lote novo. Vazios não têm
-- marca — ver ESTOQUE_VAZIOS, porque o mesmo vasilhame físico pode ser
-- enchido por marcas diferentes ao longo do tempo)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lotes_garrafao (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  marca_id     UUID NOT NULL REFERENCES marcas(id) ON DELETE RESTRICT,
  ano_validade INTEGER NOT NULL CHECK (ano_validade BETWEEN 2000 AND 2100),
  qtd_cheios   INTEGER NOT NULL DEFAULT 0 CHECK (qtd_cheios >= 0),
  status       TEXT NOT NULL DEFAULT 'ativo' CHECK (status IN ('ativo','esgotado','vencido','descontinuado')),
  observacao   TEXT,
  criado_em    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_lote_marca_ano UNIQUE (marca_id, ano_validade)
);

CREATE INDEX IF NOT EXISTS idx_lotes_marca        ON lotes_garrafao(marca_id);
CREATE INDEX IF NOT EXISTS idx_lotes_ano_validade ON lotes_garrafao(ano_validade);
CREATE INDEX IF NOT EXISTS idx_lotes_status       ON lotes_garrafao(status);

-- ------------------------------------------------------------
-- 4b. ESTOQUE_VAZIOS (pool global de vasilhames vazios por ano de
-- validade, sem marca — o vasilhame físico pode voltar a ser enchido
-- por qualquer marca)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS estoque_vazios (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ano_validade INTEGER NOT NULL UNIQUE CHECK (ano_validade BETWEEN 2000 AND 2100),
  quantidade   INTEGER NOT NULL DEFAULT 0 CHECK (quantidade >= 0),
  criado_em    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ------------------------------------------------------------
-- 4c. ESTOQUE_GAS (gás não tem validade nem lote por data — é só um
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
-- Não há mais saldo/limite agregado por cliente (era exclusivo do fiado,
-- removido). Pendência de pagamento é controlada por pedido (ver
-- pagamentos_pedido), agregada on-the-fly quando necessário.
CREATE TABLE IF NOT EXISTS clientes (
  id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tipo                     TEXT NOT NULL DEFAULT 'pf' CHECK (tipo IN ('pf','pj')),
  nome                     TEXT NOT NULL,
  telefone                 TEXT,
  endereco                 TEXT,
  saldo_comodato_garrafoes INTEGER NOT NULL DEFAULT 0 CHECK (saldo_comodato_garrafoes >= 0),
  ativo                    BOOLEAN NOT NULL DEFAULT true,
  observacao               TEXT,
  criado_em                TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_clientes_nome  ON clientes(nome);

-- ------------------------------------------------------------
-- 6. PEDIDOS (cabeçalho da venda/entrega)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pedidos (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  numero          SERIAL UNIQUE, -- código curto pra identificar o pedido (#1, #2...)
  cliente_id      UUID NOT NULL REFERENCES clientes(id) ON DELETE RESTRICT,
  data            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  forma_pagamento TEXT NOT NULL CHECK (forma_pagamento IN ('dinheiro','pix','cartao_credito','misto')),
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
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pedido_id        UUID NOT NULL REFERENCES pedidos(id) ON DELETE CASCADE,
  lote_id          UUID REFERENCES lotes_garrafao(id) ON DELETE RESTRICT,
  marca_id         UUID NOT NULL REFERENCES marcas(id) ON DELETE RESTRICT,
  quantidade       INTEGER NOT NULL CHECK (quantidade > 0),
  preco_base       NUMERIC(10,2) NOT NULL DEFAULT 0, -- preço de tabela da marca, antes do desconto do cliente
  preco_unitario   NUMERIC(10,2) NOT NULL, -- preço já com desconto aplicado
  tipo_vasilhame   TEXT NOT NULL DEFAULT 'troca' CHECK (tipo_vasilhame IN ('troca','venda','comodato')),
  preco_vasilhame  NUMERIC(10,2) NOT NULL DEFAULT 0,
  criado_em        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_itens_pedido_pedido ON itens_pedido(pedido_id);
CREATE INDEX IF NOT EXISTS idx_itens_pedido_lote   ON itens_pedido(lote_id);

-- ------------------------------------------------------------
-- 8. MOVIMENTOS_ESTOQUE (ledger append-only — lote_id pra movimentos de
-- cheios de uma marca específica; ano_validade pra movimentos do pool
-- de vazios, que não tem marca)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS movimentos_estoque (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  lote_id              UUID REFERENCES lotes_garrafao(id) ON DELETE RESTRICT,
  ano_validade         INTEGER, -- usado quando o movimento é do pool de vazios (lote_id fica NULL)
  tipo                 TEXT NOT NULL CHECK (tipo IN ('entrada_fabrica','saida_venda','retorno_vazio','avaria','ajuste','reaproveitamento')),
  quantidade           INTEGER NOT NULL,
  referencia_pedido_id UUID REFERENCES pedidos(id),
  observacao           TEXT,
  data                 TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  criado_por           UUID REFERENCES usuarios(id)
);

CREATE INDEX IF NOT EXISTS idx_mov_estoque_lote ON movimentos_estoque(lote_id);
CREATE INDEX IF NOT EXISTS idx_mov_estoque_data ON movimentos_estoque(data);

-- ------------------------------------------------------------
-- 9. AVARIAS (cheio usa lote_id/marca específica; vazio usa só o ano,
-- igual ao pool de vazios)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS avarias (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  lote_id      UUID REFERENCES lotes_garrafao(id) ON DELETE RESTRICT, -- só pra tipo='cheio'
  ano_validade INTEGER, -- só pra tipo='vazio'
  tipo         TEXT NOT NULL DEFAULT 'cheio' CHECK (tipo IN ('cheio','vazio')),
  quantidade   INTEGER NOT NULL CHECK (quantidade > 0),
  motivo       TEXT,
  data         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  criado_por   UUID REFERENCES usuarios(id)
);

CREATE INDEX IF NOT EXISTS idx_avarias_lote ON avarias(lote_id);

-- ------------------------------------------------------------
-- 10. PAGAMENTOS_PEDIDO (qualquer forma de pagamento, vinculado a um
-- pedido específico; pendência é calculada on-the-fly: total do pedido
-- menos a soma dos pagamentos registrados aqui)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pagamentos_pedido (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cliente_id UUID NOT NULL REFERENCES clientes(id) ON DELETE CASCADE,
  pedido_id  UUID REFERENCES pedidos(id) ON DELETE SET NULL,
  valor      NUMERIC(10,2) NOT NULL CHECK (valor > 0),
  forma      TEXT NOT NULL DEFAULT 'dinheiro' CHECK (forma IN ('dinheiro','pix','cartao_credito')),
  data       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  observacao TEXT,
  criado_por UUID REFERENCES usuarios(id)
);

CREATE INDEX IF NOT EXISTS idx_pag_pedido_cliente ON pagamentos_pedido(cliente_id);
CREATE INDEX IF NOT EXISTS idx_pag_pedido_pedido  ON pagamentos_pedido(pedido_id);

-- ------------------------------------------------------------
-- 10b. RECEBIMENTOS_ENTREGA (declaração informativa do entregador sobre
-- o que recebeu na entrega — pode ser dividido entre formas, ex: parte
-- dinheiro + parte Pix. Não baixa o pedido: quem confirma o pagamento
-- de fato é o caixa, em pagamentos_pedido)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS recebimentos_entrega (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pedido_id     UUID NOT NULL REFERENCES pedidos(id) ON DELETE CASCADE,
  entregador_id UUID REFERENCES usuarios(id),
  forma         TEXT NOT NULL CHECK (forma IN ('dinheiro','pix','cartao_credito')),
  valor         NUMERIC(10,2) NOT NULL CHECK (valor > 0),
  data          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  criado_por    UUID REFERENCES usuarios(id)
);

CREATE INDEX IF NOT EXISTS idx_recebimentos_entrega_pedido ON recebimentos_entrega(pedido_id);

-- ------------------------------------------------------------
-- 11. MOVIMENTOS_COMODATO (empréstimo e devolução de vasilhame;
-- empréstimo soma saldo_comodato_garrafoes do cliente, devolução abate)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS movimentos_comodato (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cliente_id           UUID NOT NULL REFERENCES clientes(id) ON DELETE CASCADE,
  marca_id             UUID NOT NULL REFERENCES marcas(id) ON DELETE RESTRICT, -- informativo: qual marca originou o empréstimo
  ano_validade         INTEGER, -- só em devolução de água (credita o pool de vazios); gás e empréstimo ficam NULL
  tipo                 TEXT NOT NULL DEFAULT 'devolucao' CHECK (tipo IN ('emprestimo','devolucao')),
  quantidade           INTEGER NOT NULL CHECK (quantidade > 0),
  referencia_pedido_id UUID REFERENCES pedidos(id),
  data                 TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  criado_por           UUID REFERENCES usuarios(id)
);

CREATE INDEX IF NOT EXISTS idx_mov_comodato_cliente ON movimentos_comodato(cliente_id);

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
-- 12b. VAZIOS_DEVOLVIDOS_PEDIDO (divide o vasilhame devolvido de um item
-- de troca por ano de validade — um pedido de 50 garrafões pode voltar
-- com 25 vazios de validade 2028 e 25 de 2029, por exemplo)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS vazios_devolvidos_pedido (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  item_pedido_id UUID NOT NULL REFERENCES itens_pedido(id) ON DELETE CASCADE,
  ano_validade   INTEGER NOT NULL CHECK (ano_validade BETWEEN 2000 AND 2100),
  quantidade     INTEGER NOT NULL CHECK (quantidade > 0),
  criado_em      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_vazios_devolvidos_item ON vazios_devolvidos_pedido(item_pedido_id);

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


-- ============================================================
-- PROCESSAMENTO DA ENTREGA (SECURITY DEFINER): roda quando status_entrega
-- passa de 'pendente' para 'entregue', seja pelo administrador/caixa ou
-- pelo entregador. É só nesse momento que o estoque (cheios/vazios) e
-- o comodato de fato se efetivam — pedido recém-criado fica "pendente"
-- sem mexer em nada disso. Por que trigger e não
-- chamadas sequenciais no JS: o entregador não tem (e não deve ter) RLS
-- de escrita em lotes_garrafao/estoque_gas/clientes/movimentos_*, então
-- isso precisa rodar com privilégio elevado no banco.
-- ============================================================
CREATE OR REPLACE FUNCTION public.processar_entrega_pedido()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  item RECORD;
  split RECORD;
  v_tem_splits BOOLEAN;
  v_total_devolvido INTEGER;
  v_diferenca INTEGER;
  v_ano_origem INTEGER;
BEGIN
  FOR item IN SELECT * FROM itens_pedido WHERE pedido_id = NEW.id LOOP

    IF item.lote_id IS NOT NULL THEN
      -- ÁGUA: baixa cheios do lote de origem (marca+ano)
      UPDATE lotes_garrafao SET qtd_cheios = GREATEST(0, qtd_cheios - item.quantidade) WHERE id = item.lote_id;
      INSERT INTO movimentos_estoque (lote_id, tipo, quantidade, referencia_pedido_id)
        VALUES (item.lote_id, 'saida_venda', -item.quantidade, NEW.id);

      IF item.tipo_vasilhame = 'troca' THEN
        SELECT EXISTS (SELECT 1 FROM vazios_devolvidos_pedido WHERE item_pedido_id = item.id) INTO v_tem_splits;

        IF v_tem_splits THEN
          -- vasilhame devolvido dividido por ano (pode ser diferente do ano vendido);
          -- vai pro pool de vazios, sem marca
          v_total_devolvido := 0;
          FOR split IN SELECT * FROM vazios_devolvidos_pedido WHERE item_pedido_id = item.id LOOP
            v_total_devolvido := v_total_devolvido + split.quantidade;
            INSERT INTO estoque_vazios (ano_validade, quantidade) VALUES (split.ano_validade, split.quantidade)
              ON CONFLICT (ano_validade) DO UPDATE SET quantidade = estoque_vazios.quantidade + EXCLUDED.quantidade;
            INSERT INTO movimentos_estoque (ano_validade, tipo, quantidade, referencia_pedido_id)
              VALUES (split.ano_validade, 'retorno_vazio', split.quantidade, NEW.id);
          END LOOP;

          -- o que faltou devolver fica como comodato (empréstimo) com o cliente
          v_diferenca := item.quantidade - v_total_devolvido;
          IF v_diferenca > 0 THEN
            UPDATE clientes SET saldo_comodato_garrafoes = saldo_comodato_garrafoes + v_diferenca WHERE id = NEW.cliente_id;
            INSERT INTO movimentos_comodato (cliente_id, marca_id, tipo, quantidade, referencia_pedido_id)
              VALUES (NEW.cliente_id, item.marca_id, 'emprestimo', v_diferenca, NEW.id);
          END IF;
        ELSE
          -- sem confirmação de ano: assume devolução total no mesmo ano vendido
          SELECT ano_validade INTO v_ano_origem FROM lotes_garrafao WHERE id = item.lote_id;
          INSERT INTO estoque_vazios (ano_validade, quantidade) VALUES (v_ano_origem, item.quantidade)
            ON CONFLICT (ano_validade) DO UPDATE SET quantidade = estoque_vazios.quantidade + EXCLUDED.quantidade;
          INSERT INTO movimentos_estoque (ano_validade, tipo, quantidade, referencia_pedido_id)
            VALUES (v_ano_origem, 'retorno_vazio', item.quantidade, NEW.id);
        END IF;
      END IF;
    ELSE
      -- GÁS: contador simples por marca, sem validade (vazio segue por marca)
      UPDATE estoque_gas SET qtd_cheios = GREATEST(0, qtd_cheios - item.quantidade) WHERE marca_id = item.marca_id;
      IF item.tipo_vasilhame = 'troca' THEN
        UPDATE estoque_gas SET qtd_vazios = qtd_vazios + item.quantidade WHERE marca_id = item.marca_id;
      END IF;
    END IF;

    IF item.tipo_vasilhame = 'comodato' THEN
      UPDATE clientes SET saldo_comodato_garrafoes = saldo_comodato_garrafoes + item.quantidade WHERE id = NEW.cliente_id;
      INSERT INTO movimentos_comodato (cliente_id, marca_id, tipo, quantidade, referencia_pedido_id)
        VALUES (NEW.cliente_id, item.marca_id, 'emprestimo', item.quantidade, NEW.id);
    END IF;

  END LOOP;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_processar_entrega_pedido ON pedidos;
CREATE TRIGGER trg_processar_entrega_pedido
  AFTER UPDATE OF status_entrega ON pedidos
  FOR EACH ROW
  WHEN (NEW.status_entrega = 'entregue' AND OLD.status_entrega = 'pendente')
  EXECUTE FUNCTION public.processar_entrega_pedido();

-- ============================================================
-- RLS POLICIES
-- ============================================================
ALTER TABLE usuarios            ENABLE ROW LEVEL SECURITY;
ALTER TABLE configuracoes       ENABLE ROW LEVEL SECURITY;
ALTER TABLE marcas              ENABLE ROW LEVEL SECURITY;
ALTER TABLE lotes_garrafao      ENABLE ROW LEVEL SECURITY;
ALTER TABLE estoque_vazios      ENABLE ROW LEVEL SECURITY;
ALTER TABLE estoque_gas         ENABLE ROW LEVEL SECURITY;
ALTER TABLE clientes            ENABLE ROW LEVEL SECURITY;
ALTER TABLE pedidos             ENABLE ROW LEVEL SECURITY;
ALTER TABLE itens_pedido        ENABLE ROW LEVEL SECURITY;
ALTER TABLE movimentos_estoque  ENABLE ROW LEVEL SECURITY;
ALTER TABLE avarias             ENABLE ROW LEVEL SECURITY;
ALTER TABLE pagamentos_pedido   ENABLE ROW LEVEL SECURITY;
ALTER TABLE recebimentos_entrega ENABLE ROW LEVEL SECURITY;
ALTER TABLE movimentos_comodato ENABLE ROW LEVEL SECURITY;
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

-- lotes_garrafao: leitura pra qualquer autenticado (entregador precisa ver
-- a validade na confirmação de entrega); escrita só administrador/caixa.
DROP POLICY IF EXISTS "lotes_admin_caixa_all" ON lotes_garrafao;
DROP POLICY IF EXISTS "lotes_select_auth" ON lotes_garrafao;
CREATE POLICY "lotes_select_auth" ON lotes_garrafao FOR SELECT
  USING (auth.role() = 'authenticated');
DROP POLICY IF EXISTS "lotes_insert_admin_caixa" ON lotes_garrafao;
CREATE POLICY "lotes_insert_admin_caixa" ON lotes_garrafao FOR INSERT
  WITH CHECK (public.current_role() IN ('administrador','caixa'));
DROP POLICY IF EXISTS "lotes_update_admin_caixa" ON lotes_garrafao;
CREATE POLICY "lotes_update_admin_caixa" ON lotes_garrafao FOR UPDATE
  USING (public.current_role() IN ('administrador','caixa')) WITH CHECK (public.current_role() IN ('administrador','caixa'));
DROP POLICY IF EXISTS "lotes_delete_admin_caixa" ON lotes_garrafao;
CREATE POLICY "lotes_delete_admin_caixa" ON lotes_garrafao FOR DELETE
  USING (public.current_role() IN ('administrador','caixa'));

-- estoque_vazios: leitura pra qualquer autenticado (entregador vê o aviso
-- de pool novo na confirmação de entrega); escrita só administrador/caixa
-- (o trigger de entrega usa SECURITY DEFINER e não passa por aqui).
DROP POLICY IF EXISTS "estoque_vazios_select_auth" ON estoque_vazios;
CREATE POLICY "estoque_vazios_select_auth" ON estoque_vazios FOR SELECT
  USING (auth.role() = 'authenticated');
DROP POLICY IF EXISTS "estoque_vazios_write_admin_caixa" ON estoque_vazios;
CREATE POLICY "estoque_vazios_write_admin_caixa" ON estoque_vazios FOR ALL
  USING (public.current_role() IN ('administrador','caixa'))
  WITH CHECK (public.current_role() IN ('administrador','caixa'));

-- estoque_gas, movimentos_estoque, avarias: administrador e caixa operam tudo.

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

DROP POLICY IF EXISTS "pagamentos_fiado_admin_caixa_all" ON pagamentos_pedido;
DROP POLICY IF EXISTS "pagamentos_pedido_admin_caixa_all" ON pagamentos_pedido;
CREATE POLICY "pagamentos_pedido_admin_caixa_all" ON pagamentos_pedido FOR ALL
  USING (public.current_role() IN ('administrador','caixa'))
  WITH CHECK (public.current_role() IN ('administrador','caixa'));

-- recebimentos_entrega: administrador/caixa têm acesso total (para
-- conferir o que o entregador declarou); entregador só lê/insere
-- declarações dos próprios pedidos de hoje.
DROP POLICY IF EXISTS "recebimentos_entrega_admin_caixa_all" ON recebimentos_entrega;
CREATE POLICY "recebimentos_entrega_admin_caixa_all" ON recebimentos_entrega FOR ALL
  USING (public.current_role() IN ('administrador','caixa'))
  WITH CHECK (public.current_role() IN ('administrador','caixa'));

DROP POLICY IF EXISTS "recebimentos_entrega_entregador_select" ON recebimentos_entrega;
CREATE POLICY "recebimentos_entrega_entregador_select" ON recebimentos_entrega FOR SELECT
  USING (
    public.current_role() = 'entregador'
    AND entregador_id = auth.uid()
  );

DROP POLICY IF EXISTS "recebimentos_entrega_entregador_insert" ON recebimentos_entrega;
CREATE POLICY "recebimentos_entrega_entregador_insert" ON recebimentos_entrega FOR INSERT
  WITH CHECK (
    public.current_role() = 'entregador'
    AND entregador_id = auth.uid()
    AND EXISTS (
      SELECT 1 FROM pedidos p
      WHERE p.id = pedido_id
        AND p.entregador_id = auth.uid()
        AND p.data::date = CURRENT_DATE
    )
  );

-- movimentos_comodato: administrador e caixa podem ver/criar/editar (tanto
-- empréstimo quanto devolução), mas só administrador pode excluir uma
-- transação (correção de erro). O empréstimo criado pela entrega do
-- pedido é inserido pelo trigger (SECURITY DEFINER), não passa por RLS.
DROP POLICY IF EXISTS "devolucoes_admin_caixa_all" ON movimentos_comodato;
DROP POLICY IF EXISTS "devolucoes_select_admin_caixa" ON movimentos_comodato;
DROP POLICY IF EXISTS "movimentos_comodato_select_admin_caixa" ON movimentos_comodato;
CREATE POLICY "movimentos_comodato_select_admin_caixa" ON movimentos_comodato FOR SELECT
  USING (public.current_role() IN ('administrador','caixa'));
DROP POLICY IF EXISTS "devolucoes_insert_admin_caixa" ON movimentos_comodato;
DROP POLICY IF EXISTS "movimentos_comodato_insert_admin_caixa" ON movimentos_comodato;
CREATE POLICY "movimentos_comodato_insert_admin_caixa" ON movimentos_comodato FOR INSERT
  WITH CHECK (public.current_role() IN ('administrador','caixa'));
DROP POLICY IF EXISTS "devolucoes_update_admin_caixa" ON movimentos_comodato;
DROP POLICY IF EXISTS "movimentos_comodato_update_admin_caixa" ON movimentos_comodato;
CREATE POLICY "movimentos_comodato_update_admin_caixa" ON movimentos_comodato FOR UPDATE
  USING (public.current_role() IN ('administrador','caixa')) WITH CHECK (public.current_role() IN ('administrador','caixa'));
DROP POLICY IF EXISTS "devolucoes_delete_admin" ON movimentos_comodato;
DROP POLICY IF EXISTS "movimentos_comodato_delete_admin" ON movimentos_comodato;
CREATE POLICY "movimentos_comodato_delete_admin" ON movimentos_comodato FOR DELETE
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

-- clientes: administrador/caixa podem ver/criar/editar; só administrador pode excluir um
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

-- vazios_devolvidos_pedido: administrador/caixa têm acesso total;
-- entregador só insere/lê linhas dos itens dos pedidos de hoje
-- atribuídos a ele (informa o ano do vasilhame devolvido na entrega).
DROP POLICY IF EXISTS "vazios_devolvidos_admin_caixa_all" ON vazios_devolvidos_pedido;
CREATE POLICY "vazios_devolvidos_admin_caixa_all" ON vazios_devolvidos_pedido FOR ALL
  USING (public.current_role() IN ('administrador','caixa'))
  WITH CHECK (public.current_role() IN ('administrador','caixa'));

DROP POLICY IF EXISTS "vazios_devolvidos_entregador_select" ON vazios_devolvidos_pedido;
CREATE POLICY "vazios_devolvidos_entregador_select" ON vazios_devolvidos_pedido FOR SELECT
  USING (
    public.current_role() = 'entregador'
    AND EXISTS (
      SELECT 1 FROM itens_pedido ip JOIN pedidos p ON p.id = ip.pedido_id
      WHERE ip.id = vazios_devolvidos_pedido.item_pedido_id
        AND p.entregador_id = auth.uid() AND p.data::date = CURRENT_DATE
    )
  );

DROP POLICY IF EXISTS "vazios_devolvidos_entregador_insert" ON vazios_devolvidos_pedido;
CREATE POLICY "vazios_devolvidos_entregador_insert" ON vazios_devolvidos_pedido FOR INSERT
  WITH CHECK (
    public.current_role() = 'entregador'
    AND EXISTS (
      SELECT 1 FROM itens_pedido ip JOIN pedidos p ON p.id = ip.pedido_id
      WHERE ip.id = vazios_devolvidos_pedido.item_pedido_id
        AND p.entregador_id = auth.uid() AND p.data::date = CURRENT_DATE
    )
  );

ALTER TABLE vazios_devolvidos_pedido ENABLE ROW LEVEL SECURITY;

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

-- ============================================================
-- MIGRAÇÃO: ciclo de vida do pedido (pagamento/entrega passam a ser
-- confirmados separadamente; estoque e débito de fiado só se efetivam
-- na entrega), desconto exibido no resumo, ano de validade do vasilhame
-- devolvido, e comodato como ledger de empréstimo+devolução
-- ============================================================
-- ALTER TABLE itens_pedido ADD COLUMN IF NOT EXISTS preco_base NUMERIC(10,2) NOT NULL DEFAULT 0;
-- ALTER TABLE itens_pedido ADD COLUMN IF NOT EXISTS ano_validade_vazio INTEGER;
--
-- ALTER TABLE pagamentos_fiado RENAME TO pagamentos_pedido;
-- ALTER INDEX IF EXISTS idx_pag_fiado_cliente RENAME TO idx_pag_pedido_cliente;
-- ALTER INDEX IF EXISTS idx_pag_fiado_pedido RENAME TO idx_pag_pedido_pedido;
--
-- ALTER TABLE devolucoes_comodato RENAME TO movimentos_comodato;
-- ALTER TABLE movimentos_comodato ADD COLUMN IF NOT EXISTS tipo TEXT NOT NULL DEFAULT 'devolucao' CHECK (tipo IN ('emprestimo','devolucao'));
-- ALTER TABLE movimentos_comodato ADD COLUMN IF NOT EXISTS marca_id UUID REFERENCES marcas(id);
-- ALTER TABLE movimentos_comodato ADD COLUMN IF NOT EXISTS referencia_pedido_id UUID REFERENCES pedidos(id);
-- ALTER TABLE movimentos_comodato ALTER COLUMN lote_id DROP NOT NULL;
-- UPDATE movimentos_comodato m SET marca_id = l.marca_id FROM lotes_garrafao l WHERE m.lote_id = l.id AND m.marca_id IS NULL;
-- ALTER TABLE movimentos_comodato ALTER COLUMN marca_id SET NOT NULL;
-- ALTER INDEX IF EXISTS idx_devolucoes_cliente RENAME TO idx_mov_comodato_cliente;
--
-- DROP POLICY IF EXISTS "pagamentos_fiado_admin_caixa_all" ON pagamentos_pedido;
-- CREATE POLICY "pagamentos_pedido_admin_caixa_all" ON pagamentos_pedido FOR ALL
--   USING (public.current_role() IN ('administrador','caixa'))
--   WITH CHECK (public.current_role() IN ('administrador','caixa'));
--
-- DROP POLICY IF EXISTS "devolucoes_admin_caixa_all" ON movimentos_comodato;
-- DROP POLICY IF EXISTS "devolucoes_select_admin_caixa" ON movimentos_comodato;
-- DROP POLICY IF EXISTS "devolucoes_insert_admin_caixa" ON movimentos_comodato;
-- DROP POLICY IF EXISTS "devolucoes_update_admin_caixa" ON movimentos_comodato;
-- DROP POLICY IF EXISTS "devolucoes_delete_admin" ON movimentos_comodato;
-- CREATE POLICY "movimentos_comodato_select_admin_caixa" ON movimentos_comodato FOR SELECT
--   USING (public.current_role() IN ('administrador','caixa'));
-- CREATE POLICY "movimentos_comodato_insert_admin_caixa" ON movimentos_comodato FOR INSERT
--   WITH CHECK (public.current_role() IN ('administrador','caixa'));
-- CREATE POLICY "movimentos_comodato_update_admin_caixa" ON movimentos_comodato FOR UPDATE
--   USING (public.current_role() IN ('administrador','caixa')) WITH CHECK (public.current_role() IN ('administrador','caixa'));
-- CREATE POLICY "movimentos_comodato_delete_admin" ON movimentos_comodato FOR DELETE
--   USING (public.current_role() = 'administrador');
--
-- CREATE OR REPLACE FUNCTION public.processar_entrega_pedido()
-- RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
-- DECLARE
--   item RECORD;
--   v_lote_destino_id UUID;
--   v_ano_destino INTEGER;
-- BEGIN
--   FOR item IN SELECT * FROM itens_pedido WHERE pedido_id = NEW.id LOOP
--     IF item.lote_id IS NOT NULL THEN
--       UPDATE lotes_garrafao SET qtd_cheios = GREATEST(0, qtd_cheios - item.quantidade) WHERE id = item.lote_id;
--       INSERT INTO movimentos_estoque (lote_id, tipo, quantidade, referencia_pedido_id)
--         VALUES (item.lote_id, 'saida_venda', -item.quantidade, NEW.id);
--       IF item.tipo_vasilhame = 'troca' THEN
--         v_ano_destino := COALESCE(item.ano_validade_vazio, (SELECT ano_validade FROM lotes_garrafao WHERE id = item.lote_id));
--         SELECT id INTO v_lote_destino_id FROM lotes_garrafao
--           WHERE marca_id = item.marca_id AND ano_validade = v_ano_destino
--           ORDER BY data_chegada DESC LIMIT 1;
--         IF v_lote_destino_id IS NULL THEN
--           INSERT INTO lotes_garrafao (marca_id, ano_validade, qtd_cheios, qtd_vazios, observacao)
--             VALUES (item.marca_id, v_ano_destino, 0, 0, 'Lote criado automaticamente ao registrar vasilhame devolvido')
--             RETURNING id INTO v_lote_destino_id;
--         END IF;
--         UPDATE lotes_garrafao SET qtd_vazios = qtd_vazios + item.quantidade WHERE id = v_lote_destino_id;
--         INSERT INTO movimentos_estoque (lote_id, tipo, quantidade, referencia_pedido_id)
--           VALUES (v_lote_destino_id, 'retorno_vazio', item.quantidade, NEW.id);
--       END IF;
--     ELSE
--       UPDATE estoque_gas SET qtd_cheios = GREATEST(0, qtd_cheios - item.quantidade) WHERE marca_id = item.marca_id;
--       IF item.tipo_vasilhame = 'troca' THEN
--         UPDATE estoque_gas SET qtd_vazios = qtd_vazios + item.quantidade WHERE marca_id = item.marca_id;
--       END IF;
--     END IF;
--     IF item.tipo_vasilhame = 'comodato' THEN
--       UPDATE clientes SET saldo_comodato_garrafoes = saldo_comodato_garrafoes + item.quantidade WHERE id = NEW.cliente_id;
--       INSERT INTO movimentos_comodato (cliente_id, marca_id, tipo, quantidade, referencia_pedido_id)
--         VALUES (NEW.cliente_id, item.marca_id, 'emprestimo', item.quantidade, NEW.id);
--     END IF;
--   END LOOP;
--   IF NEW.forma_pagamento = 'fiado' THEN
--     UPDATE clientes SET saldo_fiado = saldo_fiado + NEW.total WHERE id = NEW.cliente_id;
--   END IF;
--   RETURN NEW;
-- END;
-- $$;
--
-- DROP TRIGGER IF EXISTS trg_processar_entrega_pedido ON pedidos;
-- CREATE TRIGGER trg_processar_entrega_pedido
--   AFTER UPDATE OF status_entrega ON pedidos
--   FOR EACH ROW
--   WHEN (NEW.status_entrega = 'entregue' AND OLD.status_entrega = 'pendente')
--   EXECUTE FUNCTION public.processar_entrega_pedido();

-- ============================================================
-- MIGRAÇÃO: entregador informa o ano do vasilhame devolvido na
-- confirmação da entrega (não mais no cadastro do pedido)
-- ============================================================
-- DROP POLICY IF EXISTS "itens_pedido_entregador_update" ON itens_pedido;
-- CREATE POLICY "itens_pedido_entregador_update" ON itens_pedido FOR UPDATE
--   USING (
--     public.current_role() = 'entregador'
--     AND EXISTS (SELECT 1 FROM pedidos p WHERE p.id = itens_pedido.pedido_id AND p.entregador_id = auth.uid() AND p.data::date = CURRENT_DATE)
--   )
--   WITH CHECK (
--     public.current_role() = 'entregador'
--     AND EXISTS (SELECT 1 FROM pedidos p WHERE p.id = itens_pedido.pedido_id AND p.entregador_id = auth.uid() AND p.data::date = CURRENT_DATE)
--   );
--
-- CREATE OR REPLACE FUNCTION public.guard_itens_pedido_entregador()
-- RETURNS TRIGGER LANGUAGE plpgsql AS $$
-- BEGIN
--   IF public.current_role() = 'entregador' THEN
--     IF NEW.pedido_id IS DISTINCT FROM OLD.pedido_id
--        OR NEW.lote_id IS DISTINCT FROM OLD.lote_id
--        OR NEW.marca_id IS DISTINCT FROM OLD.marca_id
--        OR NEW.quantidade IS DISTINCT FROM OLD.quantidade
--        OR NEW.preco_base IS DISTINCT FROM OLD.preco_base
--        OR NEW.preco_unitario IS DISTINCT FROM OLD.preco_unitario
--        OR NEW.tipo_vasilhame IS DISTINCT FROM OLD.tipo_vasilhame
--        OR NEW.preco_vasilhame IS DISTINCT FROM OLD.preco_vasilhame THEN
--       RAISE EXCEPTION 'entregador só pode informar o ano de validade do vasilhame devolvido';
--     END IF;
--   END IF;
--   RETURN NEW;
-- END;
-- $$;
--
-- DROP TRIGGER IF EXISTS trg_guard_itens_pedido_entregador ON itens_pedido;
-- CREATE TRIGGER trg_guard_itens_pedido_entregador
--   BEFORE UPDATE ON itens_pedido
--   FOR EACH ROW EXECUTE FUNCTION public.guard_itens_pedido_entregador();

-- ============================================================
-- MIGRAÇÃO: lotes_garrafao passa a ter leitura liberada pra qualquer
-- autenticado (entregador precisa ver a validade na tela de confirmar
-- entrega), mantendo escrita restrita a administrador/caixa
-- ============================================================
-- DROP POLICY IF EXISTS "lotes_admin_caixa_all" ON lotes_garrafao;
-- CREATE POLICY "lotes_select_auth" ON lotes_garrafao FOR SELECT
--   USING (auth.role() = 'authenticated');
-- CREATE POLICY "lotes_insert_admin_caixa" ON lotes_garrafao FOR INSERT
--   WITH CHECK (public.current_role() IN ('administrador','caixa'));
-- CREATE POLICY "lotes_update_admin_caixa" ON lotes_garrafao FOR UPDATE
--   USING (public.current_role() IN ('administrador','caixa')) WITH CHECK (public.current_role() IN ('administrador','caixa'));
-- CREATE POLICY "lotes_delete_admin_caixa" ON lotes_garrafao FOR DELETE
--   USING (public.current_role() IN ('administrador','caixa'));

-- ============================================================
-- MIGRAÇÃO: vasilhame devolvido pode ser dividido por ano de validade
-- (ex: 50 vendidos val. 2028, devolve 25 val. 2028 + 25 val. 2029).
-- Substitui a coluna itens_pedido.ano_validade_vazio (rodar esse bloco
-- inteiro de uma vez no SQL Editor)
-- ============================================================
-- CREATE TABLE IF NOT EXISTS vazios_devolvidos_pedido (
--   id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
--   item_pedido_id UUID NOT NULL REFERENCES itens_pedido(id) ON DELETE CASCADE,
--   ano_validade   INTEGER NOT NULL CHECK (ano_validade BETWEEN 2000 AND 2100),
--   quantidade     INTEGER NOT NULL CHECK (quantidade > 0),
--   criado_em      TIMESTAMPTZ NOT NULL DEFAULT NOW()
-- );
-- CREATE INDEX IF NOT EXISTS idx_vazios_devolvidos_item ON vazios_devolvidos_pedido(item_pedido_id);
-- ALTER TABLE vazios_devolvidos_pedido ENABLE ROW LEVEL SECURITY;
--
-- CREATE POLICY "vazios_devolvidos_admin_caixa_all" ON vazios_devolvidos_pedido FOR ALL
--   USING (public.current_role() IN ('administrador','caixa'))
--   WITH CHECK (public.current_role() IN ('administrador','caixa'));
-- CREATE POLICY "vazios_devolvidos_entregador_select" ON vazios_devolvidos_pedido FOR SELECT
--   USING (
--     public.current_role() = 'entregador'
--     AND EXISTS (SELECT 1 FROM itens_pedido ip JOIN pedidos p ON p.id = ip.pedido_id WHERE ip.id = vazios_devolvidos_pedido.item_pedido_id AND p.entregador_id = auth.uid() AND p.data::date = CURRENT_DATE)
--   );
-- CREATE POLICY "vazios_devolvidos_entregador_insert" ON vazios_devolvidos_pedido FOR INSERT
--   WITH CHECK (
--     public.current_role() = 'entregador'
--     AND EXISTS (SELECT 1 FROM itens_pedido ip JOIN pedidos p ON p.id = ip.pedido_id WHERE ip.id = vazios_devolvidos_pedido.item_pedido_id AND p.entregador_id = auth.uid() AND p.data::date = CURRENT_DATE)
--   );
--
-- DROP POLICY IF EXISTS "itens_pedido_entregador_update" ON itens_pedido;
-- DROP TRIGGER IF EXISTS trg_guard_itens_pedido_entregador ON itens_pedido;
-- ALTER TABLE itens_pedido DROP COLUMN IF EXISTS ano_validade_vazio;
--
-- (recriar a função public.processar_entrega_pedido() com o corpo novo,
-- que lê vazios_devolvidos_pedido em vez de ano_validade_vazio — copie o
-- bloco "PROCESSAMENTO DA ENTREGA" completo deste arquivo e rode de novo,
-- é seguro porque é CREATE OR REPLACE)

-- ============================================================
-- MIGRAÇÃO: separa vazios (pool global por ano de validade, sem marca)
-- de cheios (lote único por marca+ano, que só acumula — chegadas
-- seguintes do mesmo marca+ano atualizam o mesmo lote em vez de criar
-- um novo). Script completo enviado ao usuário fora deste arquivo por
-- ser extenso (consolida lotes duplicados, migra avarias/comodato/
-- movimentos_estoque pra usar ano_validade em vez de lote_id quando o
-- assunto é vazio, e recria a função processar_entrega_pedido).
--
-- IMPORTANTE: a versão original usava CREATE TEMP TABLE pra mapear os
-- lotes duplicados, mas o editor SQL do Supabase não preserva tabela
-- temporária entre os comandos do mesmo script (pooler de conexões
-- troca de sessão entre statements) — deu erro "lote_merge_map does
-- not exist". A versão corrigida (enviada ao usuário) usa CTEs
-- recalculadas em cada UPDATE/DELETE em vez de tabela temporária, e o
-- passo de migrar qtd_vazios pra estoque_vazios usa "DO UPDATE SET
-- quantidade = EXCLUDED.quantidade" (substituição, não soma) pra ser
-- seguro re-rodar o script inteiro do zero mesmo após uma tentativa
-- que falhou no meio.

-- ============================================================
-- MIGRAÇÃO: remove fiado (saldo/limite agregado por cliente) e cria
-- cartão de crédito; número curto do pedido; reaproveitamento de
-- vazios na entrada de garrafão. Script completo enviado ao usuário.
-- ============================================================

-- ============================================================
-- MIGRAÇÃO: recebimentos_entrega (declaração informativa do entregador
-- sobre o que recebeu na entrega, podendo dividir entre formas — ex:
-- parte dinheiro + parte Pix. Não baixa o pedido: a confirmação oficial
-- do pagamento continua sendo feita pelo caixa em pagamentos_pedido)
-- ============================================================
-- CREATE TABLE IF NOT EXISTS recebimentos_entrega (
--   id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
--   pedido_id     UUID NOT NULL REFERENCES pedidos(id) ON DELETE CASCADE,
--   entregador_id UUID REFERENCES usuarios(id),
--   forma         TEXT NOT NULL CHECK (forma IN ('dinheiro','pix','cartao_credito')),
--   valor         NUMERIC(10,2) NOT NULL CHECK (valor > 0),
--   data          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
--   criado_por    UUID REFERENCES usuarios(id)
-- );
-- CREATE INDEX IF NOT EXISTS idx_recebimentos_entrega_pedido ON recebimentos_entrega(pedido_id);
-- ALTER TABLE recebimentos_entrega ENABLE ROW LEVEL SECURITY;
--
-- CREATE POLICY "recebimentos_entrega_admin_caixa_all" ON recebimentos_entrega FOR ALL
--   USING (public.current_role() IN ('administrador','caixa'))
--   WITH CHECK (public.current_role() IN ('administrador','caixa'));
--
-- CREATE POLICY "recebimentos_entrega_entregador_select" ON recebimentos_entrega FOR SELECT
--   USING (
--     public.current_role() = 'entregador'
--     AND entregador_id = auth.uid()
--   );
--
-- CREATE POLICY "recebimentos_entrega_entregador_insert" ON recebimentos_entrega FOR INSERT
--   WITH CHECK (
--     public.current_role() = 'entregador'
--     AND entregador_id = auth.uid()
--     AND EXISTS (
--       SELECT 1 FROM pedidos p
--       WHERE p.id = pedido_id
--         AND p.entregador_id = auth.uid()
--         AND p.data::date = CURRENT_DATE
--     )
--   );

-- ============================================================
-- MIGRAÇÃO: forma de pagamento "misto" (Dinheiro + Pix) no Novo Pedido.
-- O caixa informa quanto já recebeu em dinheiro na hora (vira um
-- pagamentos_pedido confirmado de imediato) e o restante fica registrado
-- como Pix pendente, pra ser conferido/baixado pelo adm depois.
-- ============================================================
-- ALTER TABLE pedidos DROP CONSTRAINT IF EXISTS pedidos_forma_pagamento_check;
-- ALTER TABLE pedidos ADD CONSTRAINT pedidos_forma_pagamento_check
--   CHECK (forma_pagamento IN ('dinheiro','pix','cartao_credito','misto'));

-- Após rodar este script, crie o primeiro usuário em:
-- Authentication > Users > Add user (email + senha)
-- e depois rode (substituindo o UUID pelo id do usuário criado):
--
-- INSERT INTO usuarios (id, nome, role) VALUES ('<uuid-do-usuario>', 'Seu Nome', 'administrador');
