# Sicurezza

Progetto personale: nessun programma di ricompense. Per segnalare un problema scrivi privatamente al proprietario del repository (non aprire una issue pubblica) con passi per riprodurlo e impatto. Si risponde appena possibile.

Principi (vedi ADR 0001 e 0017): i dati di salute non lasciano il dispositivo, ogni richiesta al Worker passa da Cloudflare Access, il database non è raggiungibile dai client, i segreti stanno solo in `wrangler secret` e GitHub Secrets.
