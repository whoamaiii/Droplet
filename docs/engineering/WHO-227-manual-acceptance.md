# WHO-227 — siste manuelle kontroller

Status: **Dvale brukerbekreftet gjennomført og godkjent.** Quentin opplyste i samtalen at han har utført dvaletesten manuelt og ba om å anse den som gjort. Bygg, varighet og aktivitet under testen ble ikke oppgitt; disse detaljene tilskrives ikke testen. Øvrige kontroller nedenfor er fortsatt ikke bekreftet.

De automatiske kontrollene og eksisterende native observasjoner er dokumentert i [fremdriftsrapporten](WHO-227-progress.md). WHO-227 er fortsatt In Progress for øvrige åpne kontroller. Quentin har uttrykkelig instruert videre arbeid med neste oppgave; WHO-228 er derfor startet uten å fremstille alle WHO-227-kontroller som bestått.

## Før økten — utføres av agenten

- Avtal tidspunkt med Quentin. Dvale og særlig utlogging kan avbryte annet arbeid. Utlogging trenger en separat avtale; et ja til kort dvale gir ikke tillatelse til utlogging.
- Registrer eksisterende installert app, prosess og filhash. Bruk bare en separat `--preview`-bygging med bundle-ID `local.quentinthiessen.droplet.preview`. Ikke endre LaunchAgent eller erstatt installert app.
- Start `scripts/serve-ui-fixture.py --chunk-delay 2` og behold serverens faktiske prosess-/øktidentifikator. Bygg preview med URL og isolert Downloads-mappe fra serverens JSON via `DROPLET_PREVIEW_URL` og `DROPLET_PREVIEW_DOWNLOADS`. Åpne testappen gjennom godkjent UI-kontroll.
- Kontroller at en ekte lokal videonedlasting starter. Knappene Fetch/Video/Audio/Merge/Finish er syntetisk visning og skal ikke brukes som bevis på reell aktivitet.
- Registrer testappens PID, barn og låseier før den fysiske testen. Ikke gjenbruk historiske PID-er fra rapporten.

## A. Kort dvale under ekte nedlasting

Quentin gjør bare de fysiske handlingene når agenten sier at nedlastingen er i gang:

1. Velg Dvale fra Apple-menyen mens testappen viser aktiv fremdrift.
2. Vent omtrent 15–30 sekunder, vekk Mac-en og lås opp selv om nødvendig.
3. Åpne testappens vindu og observer om fremdriften fortsetter eller om en tydelig feil med mulighet for nytt forsøk vises.

Agenten registrerer deretter faktisk resultat: synlig UI, respons på knapper, antall testinstanser/låseiere, prosessbarn og output/staging. Fullført resultat må være en lesbar, dekodbar mediefil. En avbrutt forbindelse kan gi en ærlig, gjenopprettbar feil; en evig fastlåst fremdriftsindikator eller falsk suksess er feil. Ved feil prøves samme opprinnelige URL igjen og en fullført fil verifiseres. Gjenta med appen inaktiv for å kontrollere at vanlig åpning fortsatt virker etter oppvåkning.

Langvarig dvale er en separat test: tiden teller mot dagens veggklokkebaserte watchdog. Dokumenter om denne gir en forståelig timeout etter oppvåkning og om nytt forsøk lykkes. Ikke påstå at kort dvale beviser lang dvale.

## B. Brukbart vindu etter ventende instans overtar

1. Start en inaktiv preview. Noter eier-PID og lås.
2. Klikk Launch dormant én gang. Noter PID-en fra vindustittelen og bekreft at den nye prosessen venter uten egen lås/UI.
3. Agenten avslutter kun den identifiserte, inaktive QA-eieren. Ikke bruk vanlig Quit her: den rydder også andre Droplet-instanser og er derfor ikke en overtakelsestest.
4. Vent på den eksisterende tresekunderskontrollen. Quentin observerer om testvinduet vises, og klikker Open popover for å bekrefte at grensesnittet virker. Kontroller åpning/lukking og en ekte lokal nedlasting fra etterfølgeren.
5. Agenten kobler observasjonen til den samme etterfølger-PID-en, låsen og livssyklusloggen. At loggen sier `windowVisible=true` er støttebevis, ikke erstatning for faktisk brukskontroll.

Et launchd-lignende preview-flagg beviser kodeveien, ikke en faktisk KeepAlive-registrering eller fravær av respawn i launchd. Eventuell slik kontroll må utføres isolert med egen QA-label og separat dokumentert opprydding; brukerens eksisterende LaunchAgent skal ikke endres.

## C. Systemutlogging/-avslutning

Native NSApp.terminate-delegat er allerede kontrollert. En fysisk systemøkt er ikke det samme beviset. Planlegg denne delen separat på en egnet testøkt/Mac der annet arbeid er lagret. Registrer aktive QA-jobber før systemhandling og kontroller etterpå at ingen QA-barn eller korrupte publiserte resultater består, og at neste normale oppstart virker. Registrer om det ble testet utlogging eller full maskinavslutning; ikke bruk det ene som bevis for alle systemhendelser.

## Resultatjournal — fylles ut etter handlingene

| Kontroll | Tid, bygg og PID | Faktisk observasjon | Bevis | Resultat |
| --- | --- | --- | --- | --- |
| Dvale, brukerens manuelle test | Ikke oppgitt | Quentin bekrefter gjennomført og ber om godkjenning | Direkte melding i samtalen | Brukerbekreftet bestått |
| Kort dvale, aktiv nedlasting | Ikke utført | — | — | Åpen |
| Dvale, inaktiv app | Ikke utført | — | — | Åpen |
| Lang dvale / gjenoppretting | Ikke utført | — | — | Åpen |
| Etterfølgerens UI og nedlasting | Ikke utført | — | — | Åpen |
| Fysisk systemøkt | Ikke utført | — | — | Åpen |

Etter økten stopper agenten bare registrerte QA-prosesser/servere, bevarer resultatbevis og kontrollerer den opprinnelig installerte appen igjen. Feil blir rettet innenfor WHO-227 og den berørte kontrollen gjentas. Før Done sammenholdes hele Linear-oppgavens akseptansekriterier med bevisene; denne listen alene erstatter ikke oppgaven.
