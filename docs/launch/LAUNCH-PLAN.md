# Droplet: fra dagens app til første betalende kunde

Kartlagt 28. september 2026. Dette er gjennomføringsplan og kodeaudit, ikke dokumentasjon på en ferdig salgslansering.

**Linear-prosjekt:** [Droplet – fra prototype til betalt Mac-app](https://linear.app/qappp/project/droplet-fra-prototype-til-betalt-mac-app-31ed7e727670)

35 oppgaver er opprettet: 33 frem mot lansering og 2 valgfrie senere oppgaver. Hver oppgave har begrunnelse, akseptansekriterier, ansvarstype, grovt innsatsanslag og faktiske blokkeringsrelasjoner. Ingen fiktiv sluttdato eller fullført-status er satt.

## Anbefalt produkt og kundereise

Én Mac-app og én lisensmodell. Kunden kan laste ned appen gratis, lagre tre nye videoer og kjøpe når prøvekvoten er brukt, eller kjøpe direkte på nettsiden og aktivere før første nedlasting. Foreslått pris er **US$4.99 én gang** i begge tilfeller. Det er liten verdi i å ha én nesten identisk pris på US$5 etter prøvebruk og US$4.99 ved direktekjøp.

1. Last ned en signert og notarized app.
2. Åpne dråpen i menylinjen og lagre tre videoer kunden har rett til å laste ned.
3. Appen viser gjenværende gratisnedlastinger. Feil, avbrudd og automatiske retry teller ikke.
4. Etter tredje nye, fullførte fil krever neste nedlasting kjøp eller aktivering.
5. Kunden betaler via leverandørens nettside og mottar kvittering/lisensnøkkel.
6. Nøkkelen valideres i Droplet. Videre nedlastinger blir tilgjengelige.
7. Kunden kan hente nøkkelen igjen, flytte en aktivering til ny Mac og motta sikre oppdateringer.

Foreslåtte rammer som fortsatt trenger en produktbeslutning: én person/to aktive Mac-er; varig bruksrett til kjøpt hovedversjon; presist oppdaterings-/supportløfte; Apple Silicon og macOS 14+ bare dersom testmatrisen består. Engangskjøp betyr ingen abonnementsfornyelse. Det må ikke annonseres som et ubegrenset løfte om all fremtidig utvikling.

En lokal prøvekvote kan bevares ved vanlig oppdatering/reinstallasjon, men kan ikke sikres perfekt mot en bruker som kontrollerer egen maskin og sletter lagring. Anbefalingen er en enkel, rettferdig prøve uten konto fremfor et omfattende identitets-/sporingssystem til et femdollarsprodukt.

## Salgskanal og lisensleverandør

**Anbefaling: direktesalg fra en liten nettside, med Lemon Squeezy som første kandidat.** De tilbyr nøkkelgenerering, aktivering/validering/deaktivering og utsending med kvitteringen. Butikken og selve produktet må godkjennes; det er ikke avklart at denne nedlastingsappen blir akseptert. Norske utbetalinger er oppført som støttet. [Lisensveiledning](https://docs.lemonsqueezy.com/guides/tutorials/license-keys), [produktregler](https://docs.lemonsqueezy.com/help/getting-started/prohibited-products), [landstøtte](https://docs.lemonsqueezy.com/help/getting-started/supported-countries).

| Rute | Relevans for Droplet |
| --- | --- |
| Lemon Squeezy | Første kandidat: hosted betaling og ferdige lisensnøkler. Aksept og faktisk pris/avgift må avklares. |
| Paddle | Alternativ Merchant of Record. Listepris 5% + US$0.50, men produkter under US$10 bes kontakte salg om pris. Lisensoppsett må vurderes separat. |
| Gumroad | Alternativ enkel butikk. Oppgitt direktegebyr 10% + US$0.50, høyere prosent enn første kandidat. |
| Mac App Store | Et eget senere løp. App Review 5.2.3 krever tillatelse fra kilder for tredjeparts medienedlasting. Nåværende CLI-/cookie-oppsett har også andre distribusjonsutfordringer. |

Kilder: [Paddle](https://www.paddle.com/pricing), [Gumroad](https://gumroad.com/pricing), [Apple 5.2.3](https://developer.apple.com/app-store/review/guidelines/#intellectual-property). Dette er en vurdering av veien videre, ingen garanti om leverandør- eller App Store-godkjenning. Direktesalg fjerner heller ikke krav til lovlig bruk eller tredjepartsvilkår.

### Økonomi ved US$4.99

Lemon Squeezys grunngebyr er 5% + US$0.50. Et **forenklet salg uten salgsavgift eller tillegg** gir derfor 4.99 − 0.2495 − 0.50 = **US$4.2405**, ca. US$4.24, før egne kostnader/skatt. Internasjonale transaksjoner og PayPal kan gi tillegg; utbetalingsgebyr og avgiftsgrunnlag påvirker også netto. Eksempel med 25% avgift inkludert i US$4.99 og internasjonalt kortgebyr: avgift US$0.998, plattformgebyr US$0.82435, igjen ca. **US$3.17 før utbetalingsgebyr og egne kostnader**. Dette er regneeksempler, ikke bekreftet butikkprising. [Gebyrgrunnlag](https://docs.lemonsqueezy.com/help/getting-started/fees).

Apple Developer Program har standardpris **US$99 per år**, eventuelt lokal pris. Dersom aktivt medlemskap allerede finnes, skal det brukes. Domene, hosting, refusjoner og vedlikehold må også budsjetteres. [Apple](https://developer.apple.com/programs/enroll/).

Merchant of Record håndterer sin del av kundesalgets avgifter; Quentins næringsstatus, inntektsføring og egne plikter må fortsatt avklares. [Skatteetaten](https://www.skatteetaten.no/bedrift-og-organisasjon/starte-og-drive/er-jeg-naringsdrivende/).

## Foreslått teknisk løsning

- Skill nedlastingsmotor, filresultat, prøvekvote, lisens og UI i testbare deler. Behold dråpedesignet og ettklikk-flyten.
- Pakk nødvendige motorfiler med appen; kunden skal ikke installere Homebrew, Python eller en JavaScript-runtime.
- La motoren levere et verifisert sluttresultat med faktisk filsti og identitet. Først da kan en gratisnedlasting telles.
- Bruk en varig jobblogg/reservasjon som avstemmer krasj og dobbelthendelser. Hele adgangskontrollen må ligge ved jobbstart, ikke bare på knappen.
- La appen kalle leverandørens offentlige License API med kundens nøkkel. Verifiser riktig butikk/produkt/variant og lagret aktiveringsinstans.
- Lagre nøkkel og minimal lisensstatus i Keychain. Ingen administrative API-nøkler i appen.
- Fastsett offline-/feilpolicy før kode skrives. Forslag: sjekk ved oppstart høyst én gang per døgn, med 30 dagers toleranse ved nettfeil. Autoritativ sperring er en annen tilstand enn timeout.
- Bruk hosted checkout; en retur-URL fra betalingssiden gir aldri alene rettighet. Manuell innliming av nøkkel er nok i v1.
- Det offentlige License API krever ikke at vi bygger en full betalingsserver. Webhooks kan bli nødvendig for automatisert refusjon; ved lavt volum kan en dokumentert manuell rutine være tilstrekkelig.
- Et vanlig JSON-svar fra et API er ikke en kryptografisk signert offline-lisens. Sterkere offline-beskyttelse ville kreve en separat signert entitlement-løsning; lokal cache skal ikke beskrives som manipulasjonssikker.
- Oppdater hele den signerte appen, inkludert motoren, gjennom en etablert løsning som Sparkle. Ingen brew upgrade i kundens app. [Sparkle](https://sparkle-project.org/documentation/).

## Dagens tilstand og viktige funn

Utgangspunkt: HEAD 591b139, fem sporede prosjektfiler, main.swift på 1265 linjer. Eksisterende main.swift/build.sh-endringer er bevart og ikke kommittert. Appkoden og build.sh er ikke endret som del av denne kartleggingen.

| Alvorlighet og bevis | Funn og konsekvens | Oppgave |
| --- | --- | --- |
| Høy, bekreftet i kode og installert bundle | Hardkodet /opt/homebrew/bin for motor og oppdatering. Ingen bundlet motor. En kundes ren Mac mangler forutsetningene. | [WHO-222 – Pakk en komplett motor som virker uten Homebrew](https://linear.app/qappp/issue/WHO-222/pakk-en-komplett-motor-som-virker-uten-homebrew) |
| Høy, reprodusert | exit 0 fra prosess uten produsert fil gir phase=done. Kan gi falsk suksess og feil prøvekvote. | [WHO-224 – Verifiser ferdig fil og unngå filnavnkollisjoner og falsk suksess](https://linear.app/qappp/issue/WHO-224/verifiser-ferdig-fil-og-unnga-filnavnkollisjoner-og-falsk-suksess) |
| Middels, reprodusert | En progresslinje delt mellom to pipe-lesinger blir mistet; rapportert 42% ble stående som 0%. | [WHO-223 – Rett parsing av oppdelte prosessmeldinger og vis reell fremdrift](https://linear.app/qappp/issue/WHO-223/rett-parsing-av-oppdelte-prosessmeldinger-og-vis-reell-fremdrift) |
| Høy, bekreftet | Retry-stigen leser automatisk cookies fra oppdagede nettlesere. Må være eksplisitt valgfritt eller utsettes. | [WHO-225 – Gjør bruk av nettleserinnlogging eksplisitt og valgfri](https://linear.app/qappp/issue/WHO-225/gjor-bruk-av-nettleserinnlogging-eksplisitt-og-valgfri) |
| Høy, bekreftet implementasjonsrisiko | Filnavn bruker bare tittel, ikke unik identitet. Ingen final-path-verifisering; /best-fallback kan bryte det generelle MP4-løftet. Faktisk kollisjon/formatutfall er ikke testet her. | [WHO-224 – Verifiser ferdig fil og unngå filnavnkollisjoner og falsk suksess](https://linear.app/qappp/issue/WHO-224/verifiser-ferdig-fil-og-unnga-filnavnkollisjoner-og-falsk-suksess) |
| Høy, bekreftet mangel | Trial, lisens, kjøpsflyt, sikker lagring og gjenoppretting er ikke implementert. | [WHO-231 – Implementer tre gratis vellykkede nedlastinger med krasjsikker kvote](https://linear.app/qappp/issue/WHO-231/implementer-tre-gratis-vellykkede-nedlastinger-med-krasjsikker-kvote), [WHO-232 – Implementer riktig produktbundet lisensaktivering og deaktivering](https://linear.app/qappp/issue/WHO-232/implementer-riktig-produktbundet-lisensaktivering-og-deaktivering) |
| Høy, bekreftet leveransegap | Installert app er ad-hoc-signert; ingen Developer ID Application-identitet i lokal nøkkelring. Ingen notarized kundeinstallasjon verifisert. | [WHO-219 – Klargjør Apple Developer-konto og Developer ID for distribusjon](https://linear.app/qappp/issue/WHO-219/klargjor-apple-developer-konto-og-developer-id-for-distribusjon), [WHO-237 – Bygg signert og notarized app, DMG og verifiserbar release-pakke](https://linear.app/qappp/issue/WHO-237/bygg-signert-og-notarized-app-dmg-og-verifiserbar-release-pakke) |
| Høy, krever avklaring | FFmpeg-bygget på maskinen har GPL-flagg. yt-dlp-kilde og yt-dlp-bundle har ikke nødvendigvis samme lisens. Full komponent-/kildekodeleveranse mangler. | [WHO-218 – Kartlegg lisenser og lovlig redistribusjon av hele nedlastingsmotoren](https://linear.app/qappp/issue/WHO-218/kartlegg-lisenser-og-lovlig-redistribusjon-av-hele-nedlastingsmotoren) |
| Middels, bekreftet feilsti i kode | build.sh tar ned en lastet LaunchAgent før kompilering, men gjenoppretter den ikke ved byggefeil. Ikke kjørt mot den ekte agenten i denne auditen. | [WHO-228 – Gjør bygge- og installasjonsflyten transaksjonell ved feil](https://linear.app/qappp/issue/WHO-228/gjor-bygge-og-installasjonsflyten-transaksjonell-ved-feil) |
| Middels, bekreftet risiko | Global yt-dlp-konfigurasjon ignoreres ikke; retry gjøres ved alle feil; vertsnavn sjekkes med contains; versjonslesing blokkerer hovedtråden. | [WHO-226 – Isoler yt-dlp-konfigurasjon og rett retry-, timeout- og URL-logikk](https://linear.app/qappp/issue/WHO-226/isoler-yt-dlp-konfigurasjon-og-rett-retry-timeout-og-url-logikk) |
| Middels, utestede kanttilfeller | Forsinket PID-opprydding og cancel→quit må testes videre. Tidligere rettinger mot globale prosessdrap finnes og skal bevares. | [WHO-227 – Bevis at avbryt, avslutt og omstart rydder bare Droplets arbeid](https://linear.app/qappp/issue/WHO-227/bevis-at-avbryt-avslutt-og-omstart-rydder-bare-droplets-arbeid) |
| Middels, kunde-/dokumentasjonsgap | Ingen Settings/About/lisensvisning; Finder åpner mappe i stedet for valgt fil. README beskriver gammel global prosessopprydding og feil byggsti. | [WHO-229 – Fullfør den lille kundeopplevelsen uten å miste dråpedesignet](https://linear.app/qappp/issue/WHO-229/fullfor-den-lille-kundeopplevelsen-uten-a-miste-drapedesignet), [WHO-242 – Lag kundestøtte, trygg diagnostikk og oppdatert dokumentasjon](https://linear.app/qappp/issue/WHO-242/lag-kundestotte-trygg-diagnostikk-og-oppdatert-dokumentasjon) |

Relevante lokale kildeområder: main.swift 82–155 (URL/retry/cookies), 173–245 (motor/argumenter/parsing), 266–287 (suksess/retry), 342–404 (oppdatering/versjon), 407–571 (prosessopprydding), 677–990 (UI), 1161–1247 (autostart/quit), build.sh 12–64 (bygg/installasjon), Info.plist (identitet/støtte).

Tidligere beskyttelse mot foreldede callbacks, bytte av URL under retry, globale prosessdrap og enkelte auto-close-/enkeltinstansproblemer er observert i dagens kode. De er ikke ført opp som om de fortsatt manglet. Nye regresjonsprøver gjenstår.

Redistribusjon må vurderes mot faktiske binærer: [yt-dlp licensing](https://github.com/yt-dlp/yt-dlp#licensing), [FFmpeg legal](https://ffmpeg.org/legal.html). Dette betyr ikke automatisk at en betalt Swift-front-end er forbudt eller må åpnes; avhengighetenes konkrete vilkår må oppfylles.

## Verifisering utført og grenser

Bestått 28.09.2026:

- Swift-typecheck med Swift 5-modus og arm64/macOS14-target.
- bash -n for build.sh, plutil -lint for Info.plist og git diff --check.
- Kilde-/Git-inspeksjon som bekrefter at tidligere lokale rettinger finnes.
- Inspeksjon av installert app: arm64, lokal bundle-ID, ad-hoc-signatur, ingen TeamIdentifier.
- Lokal motorversjon: yt-dlp 2026.08.19; FFmpeg 9.0.1 med GPL-flagg.
- Tellende, redigert nøkkelringinspeksjon: 0 Developer ID Application, 2 Apple Development; ingen hemmeligheter lagret eller vist.

To feil reprodusert:

En midlertidig kopi av dagens DownloadManager/ProcessInspector ble kompilert med en fake nedlastingsprosess i stedet for yt-dlp; debug-loggstub og utelatt lyd var eneste andre testtilpasninger. Fake-prosessen sendte progresslinjen i to biter og avsluttet med status 0 uten å lage fil. Målt resultat: progress_after_split_42_percent=0.0 og phase_after_exit_zero_without_output_file=done. Ingen faktisk nettside, cookie eller brukerfil ble brukt. Testkopier ble fjernet.

Ikke verifisert:

- Ekte GUI-/visuell kontroll: appkontroll feilet to ganger med timeoutReached.
- En ny vellykket faktisk videonedlasting, mediedekoding, ren-Mac-installasjon eller minimum macOS 14 i denne runden.
- Aktuelt Apple-medlemskap; mangel på lokal Developer ID er ikke bevis på mangel på medlemskap.
- Betalingskonto, produktaksept, faktisk kjøp, lisensnøkkel, refund eller offentlige nedlastingslenker.
- Developer ID-signert/notarized release, Intel, updater eller ekstern beta.

## Veien bakover fra en betalende kunde

**Første salg** krever godkjent publisering og verifisert live-kundereise → **live-kundereise** krever beta, ekte filresultater, ren-Mac-installasjon, lisens og checkout → **trial/lisens** krever pålitelig nedlastingsresultat, varig lagring og fastsatte produktvilkår → **ren Mac** krever pakket motor, rettigheter til komponentene, stabil appidentitet og Developer ID → **trygt utviklingsarbeid nå** begynner med å bevare dagens rettinger og gjøre kjernen testbar.

Start med [WHO-221 – Bevar lokale rettinger og etabler en testbar bygggrunnmur](https://linear.app/qappp/issue/WHO-221/bevar-lokale-rettinger-og-etabler-en-testbar-bygggrunnmur). Den kan utføres mens Quentin avklarer [WHO-216 – Fastsett v1: tre gratis filer, US$4.99 og tydelige lisensvilkår](https://linear.app/qappp/issue/WHO-216/fastsett-v1-tre-gratis-filer-usdollar499-og-tydelige-lisensvilkar), [WHO-217 – Avklar tillatt bruk og få betalingsleverandøren til å godta produktet](https://linear.app/qappp/issue/WHO-217/avklar-tillatt-bruk-og-fa-betalingsleverandoren-til-a-godta-produktet) og [WHO-219 – Klargjør Apple Developer-konto og Developer ID for distribusjon](https://linear.app/qappp/issue/WHO-219/klargjor-apple-developer-konto-og-developer-id-for-distribusjon). Parser-/fil-/cookie-rettingene er neste tekniske arbeid. Vi trenger ikke vente på Apple-konto for å rette disse.

Det er et reelt produktiseringsarbeid over flere faser, ikke bare en lisensdialog. Oppgaveanslagene er grove og overlapper; ikke summer dem til en lovet leveringsdato. Leverandør-/Apple-venting, tilgang til testmaskin og betafunn bestemmer deler av kalenderen.

## Komplett oppgaveoversikt

### 0 · Avklar produkt og eksterne porter

- [WHO-216 – Fastsett v1: tre gratis filer, US$4.99 og tydelige lisensvilkår](https://linear.app/qappp/issue/WHO-216/fastsett-v1-tre-gratis-filer-usdollar499-og-tydelige-lisensvilkar) — S · ca. 0,5 dag. Kan startes nå.
- [WHO-217 – Avklar tillatt bruk og få betalingsleverandøren til å godta produktet](https://linear.app/qappp/issue/WHO-217/avklar-tillatt-bruk-og-fa-betalingsleverandoren-til-a-godta-produktet) — S · 0,5–1 dag + leverandørventing. Kan startes nå.
- [WHO-218 – Kartlegg lisenser og lovlig redistribusjon av hele nedlastingsmotoren](https://linear.app/qappp/issue/WHO-218/kartlegg-lisenser-og-lovlig-redistribusjon-av-hele-nedlastingsmotoren) — M · 1–3 dager. Kan startes nå.
- [WHO-219 – Klargjør Apple Developer-konto og Developer ID for distribusjon](https://linear.app/qappp/issue/WHO-219/klargjor-apple-developer-konto-og-developer-id-for-distribusjon) — S · 0,5 dag + Apple-venting. Kan startes nå.
- [WHO-220 – Avklar Droplet-navn, domene og stabil appidentitet](https://linear.app/qappp/issue/WHO-220/avklar-droplet-navn-domene-og-stabil-appidentitet) — S · 0,5–1 dag. Kan startes nå.

### 1 · Stabil og selvstendig nedlastingsapp

- [WHO-221 – Bevar lokale rettinger og etabler en testbar bygggrunnmur](https://linear.app/qappp/issue/WHO-221/bevar-lokale-rettinger-og-etabler-en-testbar-bygggrunnmur) — M · 1–2 dager. Kan startes nå.
- [WHO-222 – Pakk en komplett motor som virker uten Homebrew](https://linear.app/qappp/issue/WHO-222/pakk-en-komplett-motor-som-virker-uten-homebrew) — M · 2–5 dager. Avhenger av WHO-218, WHO-221.
- [WHO-223 – Rett parsing av oppdelte prosessmeldinger og vis reell fremdrift](https://linear.app/qappp/issue/WHO-223/rett-parsing-av-oppdelte-prosessmeldinger-og-vis-reell-fremdrift) — M · 1–2 dager. Avhenger av WHO-221.
- [WHO-224 – Verifiser ferdig fil og unngå filnavnkollisjoner og falsk suksess](https://linear.app/qappp/issue/WHO-224/verifiser-ferdig-fil-og-unnga-filnavnkollisjoner-og-falsk-suksess) — M · 1–3 dager. Avhenger av WHO-223.
- [WHO-225 – Gjør bruk av nettleserinnlogging eksplisitt og valgfri](https://linear.app/qappp/issue/WHO-225/gjor-bruk-av-nettleserinnlogging-eksplisitt-og-valgfri) — M · 1–2 dager. Avhenger av WHO-221.
- [WHO-226 – Isoler yt-dlp-konfigurasjon og rett retry-, timeout- og URL-logikk](https://linear.app/qappp/issue/WHO-226/isoler-yt-dlp-konfigurasjon-og-rett-retry-timeout-og-url-logikk) — M · 1–3 dager. Avhenger av WHO-221, WHO-225.
- [WHO-227 – Bevis at avbryt, avslutt og omstart rydder bare Droplets arbeid](https://linear.app/qappp/issue/WHO-227/bevis-at-avbryt-avslutt-og-omstart-rydder-bare-droplets-arbeid) — M · 1–2 dager. Avhenger av WHO-221.
- [WHO-228 – Gjør bygge- og installasjonsflyten transaksjonell ved feil](https://linear.app/qappp/issue/WHO-228/gjor-bygge-og-installasjonsflyten-transaksjonell-ved-feil) — S · 0,5–1 dag. Avhenger av WHO-221.
- [WHO-229 – Fullfør den lille kundeopplevelsen uten å miste dråpedesignet](https://linear.app/qappp/issue/WHO-229/fullfor-den-lille-kundeopplevelsen-uten-a-miste-drapedesignet) — M · 1–3 dager. Avhenger av WHO-224, WHO-226.

### 2 · Tre gratis videoer og engangslisens

- [WHO-230 – Opprett og verifiser et engangskjøp med lisens i testbutikken](https://linear.app/qappp/issue/WHO-230/opprett-og-verifiser-et-engangskjop-med-lisens-i-testbutikken) — S · 0,5–1 dag + tilgang. Avhenger av WHO-216, WHO-217.
- [WHO-231 – Implementer tre gratis vellykkede nedlastinger med krasjsikker kvote](https://linear.app/qappp/issue/WHO-231/implementer-tre-gratis-vellykkede-nedlastinger-med-krasjsikker-kvote) — M · 1–3 dager. Avhenger av WHO-216, WHO-220, WHO-224, WHO-227.
- [WHO-232 – Implementer riktig produktbundet lisensaktivering og deaktivering](https://linear.app/qappp/issue/WHO-232/implementer-riktig-produktbundet-lisensaktivering-og-deaktivering) — M · 1–3 dager. Avhenger av WHO-221, WHO-230.
- [WHO-233 – Lagre lisens trygt og håndter frakobling og leverandørfeil](https://linear.app/qappp/issue/WHO-233/lagre-lisens-trygt-og-handter-frakobling-og-leverandorfeil) — M · 1–2 dager. Avhenger av WHO-232, WHO-220.
- [WHO-234 – Lag prøveindikator, kjøpsknapp og enkel lisensaktivering](https://linear.app/qappp/issue/WHO-234/lag-proveindikator-kjopsknapp-og-enkel-lisensaktivering) — M · 1–2 dager. Avhenger av WHO-231, WHO-233, WHO-229.
- [WHO-235 – Definer og test refusjon, tapt nøkkel og bytte av Mac](https://linear.app/qappp/issue/WHO-235/definer-og-test-refusjon-tapt-nokkel-og-bytte-av-mac) — S · 0,5–1 dag. Avhenger av WHO-230, WHO-233.
- [WHO-236 – Bevis hele prøve- og lisensmatrisen med automatiserte tester](https://linear.app/qappp/issue/WHO-236/bevis-hele-prove-og-lisensmatrisen-med-automatiserte-tester) — M · 1–2 dager. Avhenger av WHO-234, WHO-235.

### 3 · Signert installasjon og sikre oppdateringer

- [WHO-237 – Bygg signert og notarized app, DMG og verifiserbar release-pakke](https://linear.app/qappp/issue/WHO-237/bygg-signert-og-notarized-app-dmg-og-verifiserbar-release-pakke) — M · 1–3 dager. Avhenger av WHO-219, WHO-220, WHO-222, WHO-228, WHO-236.
- [WHO-238 – Erstatt brew-oppdatering med sikre oppdateringer av hele appen](https://linear.app/qappp/issue/WHO-238/erstatt-brew-oppdatering-med-sikre-oppdateringer-av-hele-appen) — M · 1–3 dager. Avhenger av WHO-222, WHO-228, WHO-220.
- [WHO-239 – Bytt privat KeepAlive-oppsett til normal valgfri start ved innlogging](https://linear.app/qappp/issue/WHO-239/bytt-privat-keepalive-oppsett-til-normal-valgfri-start-ved-innlogging) — M · 1–2 dager. Avhenger av WHO-220, WHO-227.

### 4 · Butikk, vilkår og kundestøtte

- [WHO-240 – Avklar selgeransvar, skatt, personvern og forbrukervilkår](https://linear.app/qappp/issue/WHO-240/avklar-selgeransvar-skatt-personvern-og-forbrukervilkar) — M · 1–2 dager + ekstern avklaring. Avhenger av WHO-216, WHO-217.
- [WHO-241 – Lag salgsside med gratisprøve, direktekjøp og ærlige produktløfter](https://linear.app/qappp/issue/WHO-241/lag-salgsside-med-gratisprove-direktekjop-og-aerlige-produktlofter) — M · 1–3 dager. Avhenger av WHO-220, WHO-230, WHO-240, WHO-229.
- [WHO-242 – Lag kundestøtte, trygg diagnostikk og oppdatert dokumentasjon](https://linear.app/qappp/issue/WHO-242/lag-kundestotte-trygg-diagnostikk-og-oppdatert-dokumentasjon) — S · 0,5–1 dag. Avhenger av WHO-226, WHO-235.
- [WHO-243 – Budsjetter vedlikehold og planlegg raske motor- og sikkerhetsoppdateringer](https://linear.app/qappp/issue/WHO-243/budsjetter-vedlikehold-og-planlegg-raske-motor-og) — S · 0,5–1 dag. Avhenger av WHO-216, WHO-217, WHO-238.

### 5 · Verifisert kundereise og lansering

- [WHO-244 – Test signert kundeinstallasjon på ren Mac uten utviklerverktøy](https://linear.app/qappp/issue/WHO-244/test-signert-kundeinstallasjon-pa-ren-mac-uten-utviklerverktoy) — M · 1–2 dager + maskintilgang. Avhenger av WHO-237, WHO-238, WHO-239, WHO-229.
- [WHO-245 – Verifiser støttede kilder og mediefiler med tillatt testmateriale](https://linear.app/qappp/issue/WHO-245/verifiser-stottede-kilder-og-mediefiler-med-tillatt-testmateriale) — M · 1–2 dager. Avhenger av WHO-222, WHO-224, WHO-225, WHO-226, WHO-227.
- [WHO-246 – Gjennomfør liten ekstern beta og rett funn før salg](https://linear.app/qappp/issue/WHO-246/gjennomfor-liten-ekstern-beta-og-rett-funn-for-salg) — M · 2–5 dager + tilbakemeldingstid. Avhenger av WHO-244, WHO-245, WHO-236, WHO-242.
- [WHO-247 – Verifiser live kjøp, nøkkel, fjerde video og refusjonsløp](https://linear.app/qappp/issue/WHO-247/verifiser-live-kjop-nokkel-fjerde-video-og-refusjonslop) — S · 0,5–1 dag. Avhenger av WHO-246, WHO-240, WHO-241, WHO-243.
- [WHO-248 – Godkjenn og publiser v1 med gjenopprettingsplan](https://linear.app/qappp/issue/WHO-248/godkjenn-og-publiser-v1-med-gjenopprettingsplan) — S · 0,5–1 dag. Avhenger av WHO-247, WHO-218, WHO-242.

### Etter v1 · Valgfrie utvidelser

- [WHO-249 – Vurder kø, kvalitetsvalg og lyduttrekk etter kundetilbakemeldinger](https://linear.app/qappp/issue/WHO-249/vurder-ko-kvalitetsvalg-og-lyduttrekk-etter-kundetilbakemeldinger) — M/L · avhenger av valgt funksjon. Avhenger av WHO-248.
- [WHO-250 – Vurder Intel/Universal og App Store som egne senere løp](https://linear.app/qappp/issue/WHO-250/vurder-inteluniversal-og-app-store-som-egne-senere-lop) — L · egen vurdering. Avhenger av WHO-248.

## Beslutningsgrense

Denne leveransen oppretter og verifiserer arbeidsplanen. Ingen appkilde er rettet, betalingskonto opprettet, juridisk avtale akseptert, nøkkel kjøpt, Git-commit/push utført eller salg publisert. Konto-/identitetssteg, ekstra kostnader og faktisk publisering håndteres når de konkrete, forberedte oppgavene kommer dit.

