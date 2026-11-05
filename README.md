# ReferralPilot

**An AI-assisted HL7 referral triage workflow for InterSystems IRIS AI Hub.** ReferralPilot accepts a referral as an HL7 v2 message, checks it against a searchable local policy library, evaluates synthetic clinic capacity, and asks an IRIS AI Hub agent to record a reasoned specialty, urgency, and any missing information. Every AI recommendation remains pending until a human approves it. The workflow and its audit trail are stored in IRIS.

> Contest target: InterSystems IRIS Community AI Hub build `2026.3.0AI.154.0`. AI Hub is an Early Access build. Use it only under the contest permission described in the [contest announcement](https://community.intersystems.com/post/intersystems-programming-contest-ai-agents-interoperability-workflows).

## What the demo shows

Three synthetic ORM referrals exercise distinct outcomes:

1. A complete cardiology referral gets a recommendation and waits for human approval.
2. A referral missing a required result is flagged for additional information.
3. A high-risk symptom is escalated to urgent review.

The policy knowledge base uses AI Hub's IRIS vector-backed RAG classes and local FastEmbed embeddings. The LLM is used for judgment and explanation; deterministic checks validate the recommendation and enforce the human-approval gate. The project contains no real patient data.

## Requirements

- Docker Engine with Compose v2
- The IRIS Community AI Hub build 154 image from the [AI Hub EAP portal](https://evaluation.intersystems.com/Eval/early-access/AIHub)
- An OpenAI API key for live agent decisions. Without a key, or when `REFERRALPILOT_DEMO_MODE=true`, the demo uses its deterministic replay mode so the workflow remains runnable.

## Install and run

1. In the EAP portal, select **AI Hub** and download the build 154 Community image for your platform. Choose the x64 or ARM64 archive as appropriate.
2. Load the downloaded archive and identify its full image name:

   ```bash
   docker image load -i iris-community-2026.3.0AI.154.0-docker.tar.gz
   docker images
   ```

3. Retag the loaded image to the local name used by this project (replace `<loaded-image-name>` with the name printed above):

   ```bash
   docker tag <loaded-image-name> iris-community:2026.3.0AI.154.0
   ```

4. Optional: copy `.env.example` to `.env` and set `OPENAI_API_KEY` for live agent decisions. The defaults in `docker-compose.yml` already start the app in replay mode, so no `.env` file is required. Never commit `.env` or a real API key.
5. Start the application:

   ```bash
   docker compose up --build -d
   ```

6. Check that IRIS is ready and open the dashboard:

   ```bash
   curl http://localhost:52773/api/referralpilot/health
   ```

   Open [http://localhost:52773/csp/irisapp/ReferralPilot.UI.cls](http://localhost:52773/csp/irisapp/ReferralPilot.UI.cls).

The first build installs the ZPM client and the `iris-llm` package, compiles this project's ObjectScript classes, creates the REST and CSP web applications, indexes the policy knowledge base, seeds three synthetic demo referrals, and starts the ensemble production. No AI Hub image, or image derived from it, is published by this repository.

## API

The REST API is mounted at `/api/referralpilot`:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/health` | Readiness check with agent-key, demo-mode, and knowledge-base status |
| `GET` | `/referrals` | List referrals and workflow state |
| `GET` | `/referrals/{id}` | Get one referral by id with full audit trail |
| `POST` | `/hl7` | Submit one HL7 v2 referral message (raw body, `Content-Type: text/plain`) |
| `POST` | `/referrals/{id}/triage` | Queue the AI triage decision for referral `{id}` |
| `POST` | `/referrals/{id}/approve` | Approve a pending recommendation and queue the downstream HL7 routing operation. Optional body: `{"reviewer":"...","comment":"..."}` |
| `POST` | `/referrals/{id}/reject` | Reject a pending recommendation. Optional body: `{"reviewer":"...","comment":"..."}` |
| `POST` | `/referrals/{id}/retry` | Clear the failed-attempt counter and re-queue automated triage |
| `POST` | `/referrals/{id}/manual-triage` | Human completes a referral parked by the pipeline fallback. Body: `{"specialty":"Cardiology","urgency":"URGENT","missingInformation":[],"rationale":"...","reviewer":"..."}` |
| `GET` | `/pipeline` | Pipeline health: status counts, manual queue, dead letters, alerts, recorded attempts |
| `GET` | `/deadletters` | Dead-letter records written by the fallback operation |
| `GET` | `/alerts` | Operational alerts raised by the fallback operation |
| `POST` | `/demo/reset` | Reload the three de-identified demo referrals |

The API also accepts body-based POSTs for backward compatibility: `POST /triage` with `{"id":"..."}` and `POST /review` with `{"id":"...","decision":"approved|rejected","reviewer":"...","comment":"..."}`.

The UI's **Load demo** action loads the three synthetic examples defined in `ReferralPilot.Store`. Individual examples are also provided in `data/`; submit an HL7 file as the request body to `/hl7` with `Content-Type: text/plain`.

## Workflow and safety

1. IRIS receives the HL7 message either from the `/hl7` REST endpoint or from the inbound HL7 service watching `/tmp/referralpilot-inbound`, and stores the original payload with a stable message identifier.
2. The parser extracts only the referral fields needed for triage. Duplicate message identifiers are idempotent.
3. The workflow retrieves relevant referral policy text from the IRIS vector knowledge base and reads the current synthetic clinic capacity.
4. The reviewer starts triage, which queues a typed request into `ReferralPilot.Production`. Its business process invokes the AI Hub agent and the bounded tools. Tools can record a recommendation, but cannot approve it or emit a downstream referral.
5. A human reviews the recommendation, evidence, missing information, and audit entries in the dashboard before approval or rejection.
6. After approval, `RoutingOperation` emits a downstream HL7 ORM^O01 acceptance to the receiving clinic and writes an operator-visible copy to `/tmp/referralpilot-outbound`.

Agent errors never auto-approve a referral. When no LLM key is configured, or `REFERRALPILOT_DEMO_MODE=true`, deterministic replay rules return visibly marked replay recommendations. The dashboard labels these decisions accordingly.

## Exception and human-fallback pipeline

Automation that cannot finish must never silently drop a referral. ReferralPilot therefore implements an explicit exception pipeline inside the interoperability production rather than returning a bare HTTP error:

```
POST /referrals/{id}/triage
        |
        v
  TriageProcess (Business Process)
        |   bounded retries (MAXATTEMPTS = 3)
        |   each failure -> pipeline.attempt_failed audit + status triage_retrying
        |
        +-- success -> recommendation saved, status pending_review / needs_information
        |
        +-- exhausted
              |
              v
        FallbackOperation (Business Operation)
              |-- Store.RequestManualTriage  -> status manual_triage_required
              |-- Store.AddDeadLetter        -> ^ReferralPilot("deadletter", id, n)
              |-- Store.AddAlert             -> ^ReferralPilot("alert")
              +-- dead-letter JSON written to the DeadLetterDir setting
                        |
                        v
              Human fallback: POST /referrals/{id}/manual-triage
                        |   (same specialty whitelist and urgency safety rules apply)
                        v
              status pending_review -> normal Approve / Reject gate
```

Design points:

- **Bounded retries, not infinite loops.** `TriageProcess` stops after `MAXATTEMPTS` and always returns a success status, so the Ensemble message is not re-queued forever.
- **The fallback operation is idempotent in spirit.** It records a dead letter, parks the referral, raises an alert, and writes a file an operator can act on. It never retries the agent. The dead-letter directory is the `DeadLetterDir` production setting, so it can be pointed at a shared volume without a code change.
- **Automatic recovery is still available.** `POST /referrals/{id}/retry` clears the attempt counter and re-queues triage, so an operator can recover after fixing the provider.
- **Human triage keeps every guard.** `Store.ManualTriage` reuses `RecordRecommendation`, so the specialty whitelist, urgency enumeration, and acute-symptom escalation (ROUTINE to URGENT) still apply to decisions entered by a person.
- **The dashboard surfaces the exception state.** The banner shows `manual queue / dead letters / alerts`, parked referrals render a "Pipeline fallback" panel with **Retry automated triage** and **Complete triage manually**.

New pipeline states: `triage_retrying` (an automated attempt failed and will be retried) and `manual_triage_required` (automation is exhausted and a clinician must complete triage).

## Inbound HL7 service and downstream routing

The production closes the loop around the AI decision: messages enter through a service, and only human-approved referrals leave through an operation.

```
EHR export / HL7 drop                    REST client
        |                                    |
        v                                    v
/tmp/referralpilot-inbound            POST /hl7
        |                                    |
        +----------------+-------------------+
                         v
        HL7Service (Business Service, Ens.InboundAdapter)
        |  Store.CreateFromHL7 -> idempotent by MSH-10
        |  consumed files move to /tmp/referralpilot-inbound/consumed
        v
        TriageProcess -> FallbackOperation (see the previous section)
        v
        Human Approve / Reject gate
        v  approved only
        RoutingOperation (Business Operation)
        |  every other status is audited as routing.skipped
        +-> ^ReferralPilot("outbound", id)
        +-> /tmp/referralpilot-outbound/<id>.hl7  (HL7 ORM^O01)
```

- **Transport is separated from judgment.** `HL7Service` only reads files, validates them with the same deterministic parser used by the REST endpoint, archives the source file, and queues triage. It never calls the agent directly.
- **Idempotency survives the transport.** A file whose MSH-10 was already seen produces `hl7.duplicate_ignored` and does not re-queue triage.
- **Routing is gated by human approval.** `RoutingOperation` refuses to emit anything unless the referral status is `approved`; a rejected or pending referral can never reach the downstream clinic.
- **The outbound message is a real HL7 v2 message.** `MSH-10` is `OUT-<referral id>`, `OBR-4` carries the normalized specialty code (`CARD`, `NEURO`, `ONC`, `ORTHO`, `GENERAL`), and free text is delimiter-escaped so it cannot break the pipe/caret hierarchy.
- **Delivery is best effort and observable.** A messaging failure raises an alert and writes `routing.queue_failed`; the clinician's approval is never rolled back, and the outbound payload stays in `^ReferralPilot("outbound", id)` for inspection.

Drop an HL7 file into the inbox to exercise the service without the REST API:

```bash
docker compose exec iris sh -c "mkdir -p /tmp/referralpilot-inbound && sed 's/MSG-CARDIO-001/CLINIC-20261102-A/g' /home/irisowner/dev/data/referral-cardio.hl7 > /tmp/referralpilot-inbound/clinic-1.hl7"
```

The service picks the file up within one adapter interval (5 seconds), archives it, and the new referral appears in the dashboard as `received`.

## Configuration

| Variable | Default | Description |
|---|---|---|
| `OPENAI_API_KEY` | empty | OpenAI key for live AI Hub decisions. Omit for replay mode |
| `REFERRALPILOT_MODEL` | `gpt-5-nano` | Model name passed to the AI Hub provider |
| `REFERRALPILOT_DEMO_MODE` | `true` | Forces deterministic replay mode regardless of whether a provider key is set |

Set `REFERRALPILOT_DEMO_MODE=false` and provide `OPENAI_API_KEY` to exercise live agent decisions.

The AI Hub build supports OpenAI, Anthropic, Gemini, Amazon Bedrock, and experimental providers. Adapting provider selection is isolated in `ReferralPilot.Agent`. Judges can use their own key in `.env`.

## Observability

Referral state and a chronological audit trail are persisted in IRIS globals. Each event records the referral ID, stage, actor (system, agent, or reviewer), timestamp, outcome, and relevant evidence. Agent sessions expose token and tool-call statistics in AI Hub; the UI displays the saved decision mode and the workflow trace. The Health endpoint reports `knowledgeBase`, `demoMode`, and `agentKeyConfigured` so the runtime can be diagnosed at a glance.

## Development and tests

The repository ships four unit-test classes under `src/ReferralPilot/Tests/`:

- `ReferralPilot.Tests.Store` — HL7 parsing, specialty normalization, replay triage urgency rules, safety escalation, review workflow, audit trail, edge cases.
- `ReferralPilot.Tests.Agent` — Demo-mode detection, missing-key replay fallback, unknown-referral error path.
- `ReferralPilot.Tests.Pipeline` — Attempt counting, fallback operation routing, dead-letter and alert recording, manual triage recovery, safety escalation on the human path, pipeline statistics.
- `ReferralPilot.Tests.Routing` — Approved referrals produce an outbound ORM^O01, unapproved referrals are skipped and audited, unknown referrals raise an alert, free-text escaping.

Run all tests inside the container:

```bash
docker compose exec iris iris session IRISAPP "##class(%UnitTest.Manager).RunTest(\"ReferralPilot.Tests\")"
```

Run a single test class:

```bash
docker compose exec iris iris session IRISAPP "##class(%UnitTest.Manager).RunTest(\"ReferralPilot.Tests.Store\")"
```

The API and replay mode do not require an external model key. Live Agent calls require outbound network access from the container and the configured provider key.


## License

MIT. See [LICENSE](LICENSE).
