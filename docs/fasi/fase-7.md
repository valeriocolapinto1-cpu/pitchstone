# Fase 7: quiz e ripasso

Stato: completata ([ADR 0011](../decisioni/0011-quiz.md)).

## Obiettivo

Quiz a risposta multipla, domande aperte corrette dall'AI, esercizi di calcolo, FSRS, streak, obiettivi settimanali, promemoria delle 8, avviso immediato per i ritardi.

## Criteri di completamento

- [x] Un quiz per schermata con feedback immediato (`QuizView`, ⌘R).
- [x] FSRS aggiorna le scadenze (`FSRSTests`, `StudyModelTests`).
- [x] Lo streak si azzera correttamente (`StudyPlanTests`).
- [x] Il promemoria è programmato alle 8 (`ReminderTests`); l'arrivo va verificato sull'iPad.

## Test

- [x] Test dell'algoritmo FSRS con casi noti (parametri iniziali, ritenzione 90% a t = S, intervalli crescenti, errori).
- [x] Test delle notifiche (`ReminderPlanner`: mattina, giorno saltato, streak a rischio).

## Verifica su dispositivo

- [ ] Promemoria delle 8 e avviso del giorno saltato.
- [ ] Qualità dei quiz generati in italiano.
