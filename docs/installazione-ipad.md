# Installare l'app sull'iPad senza Mac

GitHub compila l'app su un Mac in cloud (workflow `ipa`) e produce una `.ipa` **non firmata**.
Un iPad accetta solo app firmate: la firma la aggiunge, dal PC Windows, Sideloadly (o AltStore)
con il proprio Apple ID.

## 1. Scaricare la .ipa

1. GitHub → Actions → **ipa** → *Run workflow* (oppure l'ultimo run partito da `main`).
2. A run finito, in fondo alla pagina: artifact **Pitchstone-ipa** → si scarica uno zip con `Pitchstone.ipa`.

## 2. Installarla con Sideloadly (Windows)

1. Installare iTunes e iCloud **dal sito Apple** (non dal Microsoft Store): servono i driver dell'iPad.
2. Installare Sideloadly da sideloadly.io.
3. Collegare l'iPad con il cavo, sbloccarlo e scegliere "Autorizza questo computer".
4. In Sideloadly: trascinare `Pitchstone.ipa`, inserire il proprio Apple ID, *Start*. Al primo uso
   chiede la password e il codice a due fattori; la password va solo ad Apple.
5. Sull'iPad: Impostazioni → Generali → VPN e gestione dispositivi → fidarsi del proprio Apple ID.
6. Da iPadOS 16: Impostazioni → Privacy e sicurezza → **Modalità sviluppatore** attiva (riavvio).

## Limiti dell'Apple ID gratuito

- La firma dura **7 giorni**: poi l'app non si apre finché non la si reinstalla (i dati restano).
  Sideloadly può rinnovarla in automatico col PC acceso e l'iPad sulla stessa rete Wi-Fi.
- Al massimo 3 app installate così per volta.
- Con un account sviluppatore Apple (99 €/anno) la firma dura un anno ed è possibile TestFlight.

## Dopo l'installazione

Impostazioni dell'app → indirizzo del Worker, Client ID e Client Secret del service token di
Cloudflare Access → *Salva*. La sincronizzazione parte da sola.
