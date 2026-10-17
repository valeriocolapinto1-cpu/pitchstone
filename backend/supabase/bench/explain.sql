-- Piano di sync_pull dalla prima pagina e da un cursore avanzato.
explain (analyze, buffers) select public.sync_pull(0, 500);
explain (analyze, buffers) select public.sync_pull((select max(server_seq) - 1000 from public.nodes), 500);
