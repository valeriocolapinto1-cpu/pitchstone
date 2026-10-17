-- Dati di esempio non sensibili, solo per l'ambiente locale.

insert into nodes (id, type, title, body_md, area, tags, device_id) values
  ('00000000-0000-4000-8000-000000000001', 'concept', 'Derivata', 'Limite del rapporto incrementale.', 'studio', '{analisi}', 'seed'),
  ('00000000-0000-4000-8000-000000000002', 'concept', 'Integrale', 'Operazione inversa della derivata.', 'studio', '{analisi}', 'seed'),
  ('00000000-0000-4000-8000-000000000003', 'project', 'Pitchstone', 'Secondo cervello per iPad.', 'progetti', '{}', 'seed');

insert into edges (id, source_id, target_id, kind, label) values
  ('00000000-0000-4000-8000-000000000101', '00000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000002', 'manual', 'inversa di');
