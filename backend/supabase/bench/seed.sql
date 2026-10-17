-- Dati sintetici: 200 000 nodi con altrettante righe di cronologia e archi. Solo database di prova.
insert into nodes (id, type, area, title, body_md)
select gen_random_uuid(), 'note', 'studio', 'Nodo ' || g, repeat('testo ', 20)
from generate_series(1, 200000) g;
analyze nodes;
