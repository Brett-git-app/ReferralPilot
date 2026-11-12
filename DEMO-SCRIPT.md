# ReferralPilot — Live Demo Recording Script

> Purpose: narration script for the contest judges. Every timing, screen and line below has been verified against the project code.
> Suggested length: 3–4 minutes. Run `docker compose up --build -d` and make sure IRIS is healthy before recording.

---

## 📌 Pre-flight checklist

1. **Docker + IRIS are running**
   ```bash
   curl http://localhost:52773/api/referralpilot/health
   ```
   It should return `"ready": 1`. If `"demoMode": true` and `"agentKeyConfigured": false`, the app is in replay mode — that is fully recordable, and the banner clearly shows "REPLAY MODE · human approval required".
2. **Recording resolution**: 1920×1080, browser maximized, unrelated tabs closed.
3. **Browser zoom**: 100%, dark theme already loaded.
4. **Chrome or Edge recommended**; no need to open the console (judges do not look at it).

---

## 🎬 Shot list (8 scenes + 2 optional bonus scenes)

### Scene 1 — Startup and health check (~25 s)

**Screen**: terminal window next to the browser.

**Actions**:
1. Open a terminal at the project root and run:
   ```bash
   curl http://localhost:52773/api/referralpilot/health | python -m json.tool
   ```
2. Point out the JSON fields: `ready: 1`, `irisNamespace: "IRISAPP"`, `agentKeyConfigured`, `demoMode`, `knowledgeBase`.
3. Open a browser at `http://localhost:52773/csp/irisapp/ReferralPilot.UI.cls`.

**Narration** (medium pace, natural):

> "This is **ReferralPilot** — an AI-assisted HL7 referral triage workflow running on the InterSystems IRIS AI Hub. The whole backend is `docker compose up`: one IRIS Community AI Hub image runs the REST API, the Ensemble production, the AI agent and the vector knowledge base together."
>
> "The health endpoint shows the entire runtime in one line: namespace, whether an API key is configured, the demo-mode switch, and whether the knowledge base is ready or falling back."
>
> "Now the UI — it is a plain CSP page served by IRIS itself, no frontend build tooling, rendered server-side."

---

### Scene 2 — Load the three synthetic referrals (~20 s)

**Screen**: ReferralPilot UI. The left list is empty and shows "No referrals yet. Load the synthetic demo cases."

**Actions**:
1. Click **"Load demo cases"** in the top right.
2. Wait for the toast to disappear (~2.8 s).
3. The left list now shows 3 referrals, all with the grey **"received"** badge.
4. Click the first one (MSG-CARDIO-001 / Chest discomfort); the detail panel shows the clinical note.

**Narration**:

> "Three synthetic referrals covering three different clinical situations. They are all ORM^O01 HL7 v2 messages parsed directly by IRIS. Each one exercises a core rule:"
>
> "The first is exertional chest pain with no acute symptoms; the second is missing an imaging report; the third is acute chest pain with diaphoresis — high risk."
>
> "Every message is checked against MSH-10, the message control ID, before it is stored. A duplicate submission returns the same referral id instead of creating a new record."

---

### Scene 3 — Case 1: exertional chest pain → SOON (~35 s)

**Screen**: detail panel; the clinical note reads "Chest discomfort on exertion for three weeks. ECG attached. No shortness of breath at rest."

**Actions**:
1. Click **"Run AI triage"**.
2. After the toast clears (~2.8 s) the panel refreshes with an **"Agent recommendation · replay"** block.
3. Highlight:
   - Specialty tag: **Cardiology**
   - Urgency tag: **SOON** (amber)
   - Policy evidence: one policy source
4. Scroll to the audit trail: `hl7.received → triage.demo_mode → triage.recommended → triage.replay`.

**Narration**:

> "Case one — exertional chest pain, no acute findings. Click Run AI triage. The backend path is: the API receives the POST → the Ensemble production queues it → the business process asks the AI Hub agent for a recommendation. In replay mode the same business process applies the deterministic rules instead of calling the model, so the demo is repeatable without a key."
>
> "The agent never approves anything on its own. It records specialty, urgency, missing information and rationale. What you see here is a deterministic recommendation from replay mode — if you configure OPENAI_API_KEY and turn demo mode off, the same flow produces a live LLM decision, and the UI labels replay vs live clearly."
>
> "Notice the urgency is SOON, not ROUTINE — the deterministic rule recognised the word 'exertion'."

---

### Scene 4 — Case 2: missing imaging report → needs_information (~25 s)

**Screen**: click the second referral (MSG-NEURO-002 / Progressive headaches).

**Actions**:
1. The clinical note reads "Progressive headaches for six weeks. Imaging report is not attached."
2. Click **"Run AI triage"**.
3. After the refresh, the status badge turns blue: **"needs_information"**.
4. Expand the missing-information list — it contains "Attach the imaging report".

**Narration**:

> "Case two — a neurology referral whose note explicitly says the imaging report is not attached. Once the AI sees that missing item, it not only lists it under missingInformation, it also promotes the overall status from 'pending_review' to 'needs_information'."
>
> "That rule is enforced in Store.RecordRecommendation: whenever an imaging item is missing, the code appends 'Attach the imaging report'. The field is a JSON array, so the agent's tool can populate it directly."

---

### Scene 5 — Case 3: acute chest pain → URGENT + safety override (~30 s)

**Screen**: click the third referral (MSG-CARDIO-003 / Acute chest pain).

**Actions**:
1. The clinical note reads "Acute chest pain, diaphoresis and breathlessness began today. Please assess urgently."
2. Click **"Run AI triage"**.
3. The urgency tag is red: **URGENT**.

**Key demonstration**:
4. Switch to the terminal and deliberately write a ROUTINE recommendation for that referral through the real store API:
   ```bash
   docker compose exec iris iris session IRISAPP
   ```
   then in the IRIS prompt:
   ```objectscript
   set id=^ReferralPilot("message","MSG-CARDIO-003")
   set sc=##class(ReferralPilot.Store).RecordRecommendation(id,"Cardiology","ROUTINE","[]","Deliberately ROUTINE to show the safety override","RP-COMMON-01","manual")
   write sc,!
   ```
5. Refresh the UI: the urgency is still **URGENT**, because `RecordRecommendation` detects `acute chest pain`, `diaphoresis` or `breathlessness at rest` in the note and forces the escalation.

**Narration**:

> "Case three — acute chest pain, diaphoresis, breathlessness. This is the most important **safety override** demo: even if the AI agent passes ROUTINE back through a tool call, the deterministic check in Store.RecordRecommendation overrides it and forces URGENT. The agent may advise, but it cannot bypass the safety rules."
>
> "That is the design philosophy of the workflow: the agent interprets and explains, deterministic code guards the boundary."

---

### Scene 5.5 — Exception pipeline and human fallback (optional, ~30 s)

**Screen**: terminal plus the UI detail panel.

**Actions**:
1. Simulate a provider outage in the terminal and park case 2 in the manual queue:

   ```bash
   docker compose exec iris iris session IRISAPP \
     "set id=^ReferralPilot(\"message\",\"MSG-NEURO-002\"),req=##class(ReferralPilot.FallbackRequest).%New() set req.ReferralID=id,req.Reason=\"simulated provider outage\",req.Attempts=3,req.Source=\"Demo\" set op=##class(ReferralPilot.FallbackOperation).%New() do op.OnMessage(req,.resp)"
   ```

   > `^ReferralPilot("message", <MSH-10>)` stores the referral id. This line goes through the real FallbackOperation: it writes a dead letter, raises an alert and sets the referral to `manual_triage_required`.

2. Refresh the page: case 2 now shows the **manual triage required** badge, and the banner pill reads `manual queue 1 · dead letters 1 · alerts 1`.
3. The detail panel shows a **Pipeline fallback** section with `lastError`.
4. Click **Complete triage manually** → pick specialty and urgency in the dialog's dropdowns → the status returns to **pending review**.
5. Optional: open `http://localhost:52773/api/referralpilot/deadletters` in the browser to show the dead-letter record.

**Narration**:

> "When automation fails, ReferralPilot neither drops the referral nor retries forever. TriageProcess retries at most three times, writes a `pipeline.attempt_failed` audit event for each failure, and sets the status to `triage_retrying`."
>
> "After three failures it hands a FallbackRequest to FallbackOperation — which writes a dead letter, parks the referral as `manual triage required`, and raises an alert. The dead letter is also written to disk inside the container, so operations can pick it up outside IRIS."
>
> "From there the referral has exactly two paths: once the provider is healthy, an operator clicks **Retry automated triage**, or a clinician completes triage in the UI. Note that the human-entered urgency goes through the same safety override — a person cannot downgrade acute chest pain to ROUTINE either."

---

### Scene 6 — Human approval / rejection (~25 s)

**Screen**: back to case 1 (Cardiology / SOON), which should be **"pending_review"**.

**Actions**:
1. Click **"Approve"** at the bottom of the detail panel.
2. The first prompt asks "Reviewer identity:" — enter a reviewer name such as "Dr. Demo". The next prompt asks "Optional reviewer comment:" — type "Looks good, ECG confirms ischemia." and press Enter.
3. After the toast clears, the badge turns green: **"approved"**. The Approve/Reject buttons disappear.
4. Switch to case 2 (Neurology / needs_information) and click **"Reject"**.
5. Confirm the reviewer identity, then answer "Reason for rejection:" with "Imaging must be attached before triage." and press Enter.
6. The badge turns red: **"rejected"**.

**Narration**:

> "The agent recommendation is always advisory — someone must click Approve or Reject in the UI before the workflow is complete. Only approved referrals move downstream: RoutingOperation generates an HL7 ORM^O01, stores it in `^ReferralPilot("outbound", id)` and writes it to `/tmp/referralpilot-outbound`."
>
> "Rejected referrals keep their full audit trail as well — who rejected them, when, and why."

---

### Scene 6.5 — Inbound HL7 service and downstream routing operation (optional, ~30 s)

**Screen**: terminal plus the UI list.

**Actions**:
1. Simulate an external EHR dropping an HL7 file (use a different message control ID so it does not collide with the demo cases):

   ```bash
   docker compose exec iris sh -c "mkdir -p /tmp/referralpilot-inbound && sed 's/MSG-CARDIO-001/CLINIC-20261102-A/g' /home/irisowner/dev/data/referral-cardio.hl7 > /tmp/referralpilot-inbound/clinic-1.hl7"
   ```

2. Wait about 5 seconds (the adapter poll interval), refresh the page: the list gains one more referral in `received` state, and its audit contains `hl7.service_ingested`.
3. Wait for the service to queue triage automatically. When the recommendation appears, **Approve** it.
4. Inspect the outbound message in the terminal:

   ```bash
   docker compose exec iris sh -c "ls /tmp/referralpilot-outbound && cat /tmp/referralpilot-outbound/*.hl7"
   ```

   It shows `MSH|^~\&|REFERRALPILOT|IRIS|DOWNSTREAM-CLINIC|...|ORM^O01|OUT-R...` and `OBR|1|R...||CARD^Referral accepted`.

**Narration**:

> "This chain is now a complete interoperability loop, not just a REST demo."
>
> "At the front is HL7Service — a business service that polls `/tmp/referralpilot-inbound` every 5 seconds. It does exactly three things: read the file, validate it with the same deterministic parser used by the REST endpoint, and archive it into the consumed folder before queueing triage. It never calls the agent directly — transport and judgment are separate."
>
> "At the back is RoutingOperation — a business operation. It only emits messages for approved referrals; every other status is audited as routing.skipped. The message is real HL7 v2 ORM^O01: MSH-10 is OUT-<referral id>, OBR-4 carries the normalized specialty code, and free text uses standard HL7 escape sequences."
>
> "So: service in, process judges, operation out — with a human approval gate always in the middle."

---

### Scene 7 — Complete audit chain (~20 s)

**Screen**: switch back to case 1 (Cardiology / SOON, already approved) and scroll to the audit trail.

**Actions**:
1. Show the full audit trail:
   - `hl7.received` (actor: system)
   - `triage.demo_mode` (actor: system; the replay-mode switch)
   - `triage.recommended` (actor: agent, mode replay)
   - `triage.replay` (actor: system)
   - `review.approved` (actor: the reviewer name)

**Narration**:

> "Every step is written into IRIS globals, so the audit trail is complete. The actor column shows three categories: system, agent, and the named reviewer. In live mode the same trail additionally contains `tool.policy_fallback`, `tool.capacity`, and `agent.completed`; the AI Hub itself records token usage and tool-call counts, which Agent.Run reads via session.GetStats() and stores in the audit detail."

---

### Scene 8 — Closing (~20 s)

**Screen**: return to the health endpoint JSON, or stay on the UI and point at "REPLAY MODE · human approval required" in the banner.

**Narration**:

> "To summarise the core design of ReferralPilot:"
>
> "First, **IRIS interoperability plus AI Hub agents** — the production queues HL7 intake, a business process calls the AI agent, the agent uses bounded tools, and the tools write back to the store. The whole chain is native IRIS capability, with no external microservices."
>
> "Second, **safety fallbacks** — deterministic code sits above the agent: a specialty whitelist, urgency enumeration validation, forced escalation for acute symptoms, and a human approval gate."
>
> "Third, **portability** — the project runs end to end without OPENAI_API_KEY. In replay mode the deterministic rules produce predictable results, and judges can switch to live mode with their own key."
>
> "Thank you. The source code is on GitHub and the Open Exchange submission is ready."

---

## 🎥 Suggested recording settings

| Item | Value |
|---|---|
| Resolution | 1920×1080 |
| FPS | 30 |
| Output format | MP4 (H.264) |
| Length | 3.5 minutes (keep it under 5 minutes) |
| Keep out of frame | personal desktop wallpaper, email, chat windows |

## 🎯 Highlight tags (optional, added in post as captions)

- **[Security Override]** — the safety escalation in case 3
- **[Exception Pipeline]** — retry / dead letter / human fallback in Scene 5.5
- **[Interop Loop]** — the service → process → operation loop in Scene 6.5
- **[Human-in-the-loop]** — approve/reject in Scene 6
- **[AI Hub Observability]** — the audit trail in Scene 7
- **[Replay vs Live]** — the mode label in Scene 3

## 📂 File location

`DEMO-SCRIPT.md` (this file). After recording, tick the remaining items in the README contest submission checklist and reuse this script as the Open Exchange video description.
