-- Dati di esempio non sensibili, solo per l'ambiente locale.

insert into nodes (id, type, title, body_md, area, tags, device_id) values
  ('00000000-0000-4000-8000-000000000001', 'concept', 'Derivata', 'Limite del rapporto incrementale.', 'studio', '{analisi}', 'seed'),
  ('00000000-0000-4000-8000-000000000002', 'concept', 'Integrale', 'Operazione inversa della derivata.', 'studio', '{analisi}', 'seed'),
  ('00000000-0000-4000-8000-000000000003', 'project', 'Pitchstone', 'Secondo cervello per iPad.', 'progetti', '{}', 'seed');

insert into edges (id, source_id, target_id, kind, label) values
  ('00000000-0000-4000-8000-000000000101', '00000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000002', 'manual', 'inversa di');

insert into quizzes (id, node_id, area, kind, question, options, answer, difficulty, language) values
  ('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000001', 'studio', 'mcq',
   'Qual è la derivata di x^2?', '["x", "2x", "x^2", "2"]', '2x', 1, 'it');

insert into reviews (quiz_id, due_at) values
  ('00000000-0000-4000-8000-000000000201', now());
