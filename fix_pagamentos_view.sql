-- Rode este script no SQL Editor do Supabase (projeto aueepetytodhxaakvhrk).
-- Corrige o bug de pedidos não ficarem marcados como pagos.

CREATE OR REPLACE VIEW public.pagamentos_totais_pedido
WITH (security_invoker = true) AS
SELECT pedido_id, SUM(valor)::numeric AS total_pago
FROM public.pagamentos_pedido
WHERE pedido_id IS NOT NULL
GROUP BY pedido_id;

GRANT SELECT ON public.pagamentos_totais_pedido TO authenticated;
