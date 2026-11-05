Include %occStatus

/// Build and populate a local FastEmbed + IRIS vector-backed referral policy knowledge base.
Class ReferralPilot.Knowledge Extends %RegisteredObject
{

ClassMethod BuildKB(Output kb As %RegisteredObject) As %Status
{
    Try {
    Set emb=##class(%AI.RAG.Embedding.FastEmbed).Create()
    Set vs=##class(%AI.RAG.VectorStore.IRIS).%New()
    Set vs.TableName="ReferralPilot.PolicyVectors", vs.Dimensions=384, vs.ModelName="AllMiniLML6V2"
    $$$ThrowOnError(vs.Build())
    Set kb=##class(%AI.RAG.KnowledgeBase).%New()
    Set kb.Name="search_referral_policies", kb.Description="Search the local synthetic referral triage policy library. Cite policy identifiers in the recommendation."
    Set kb.TopK=3
    $$$ThrowOnError(kb.Build(emb,vs))
    If '$Data(^ReferralPilot("policyIndex")) {
        Set sc=..LoadPolicies(kb)
        $$$ThrowOnError(sc)
        Set ^ReferralPilot("policyIndex")=1
    }
    Return $$$OK
    } Catch ex {
        Return ex.AsStatus()
    }
}

ClassMethod IndexPolicies() As %Status
{
    Set sc=..BuildKB(.kb)
    If $$$ISERR(sc) {
        write "Knowledge base index skipped (vector embeddings unavailable): ",$System.Status.GetErrorText(sc),!
        Set ^ReferralPilot("kbStatus")="fallback"
        Set ^ReferralPilot("kbError")=$System.Status.GetErrorText(sc)
    } else {
        write "Knowledge base indexed successfully.",!
        Set ^ReferralPilot("kbStatus")="ready"
        Kill ^ReferralPilot("kbError")
    }
    Return $$$OK
}

ClassMethod GetKBStatus() As %String
{
    If $Data(^ReferralPilot("kbStatus")) Return ^ReferralPilot("kbStatus")
    Return "not_initialized"
}

ClassMethod LoadPolicies(kb As %RegisteredObject) As %Status
{
    Set policies=[
        ["RP-CARD-01: Cardiology referrals require symptom duration, current severity, ECG findings when available, and relevant cardiac history. Exertional chest discomfort without instability is reviewed soon. Acute chest pain with diaphoresis, syncope, or breathlessness at rest needs urgent same-day clinical escalation; this workflow must never diagnose or replace emergency services.",{"source":"RP-CARD-01","specialty":"Cardiology"}],
        ["RP-NEURO-02: Neurology referrals for progressive headache should include onset, progression, neurological red flags, and imaging report when available. If imaging is missing, request it and keep the referral pending review. Sudden severe headache or new focal deficit needs urgent clinical assessment.",{"source":"RP-NEURO-02","specialty":"Neurology"}],
        ["RP-COMMON-01: All referrals require patient identity, referring service, reason for referral, relevant history, and supporting test results where indicated. Never invent missing facts. List each missing item explicitly and leave the record for human review.",{"source":"RP-COMMON-01","specialty":"All"}],
        ["RP-OPS-01: Clinic capacity is operational context, not a reason to downgrade clinical urgency. If the preferred clinic has no capacity, recommend an alternate clinic or escalation for human coordination; do not silently discard or delay a referral.",{"source":"RP-OPS-01","specialty":"All"}],
        ["RP-GOV-01: Agent output is advisory. The agent may recommend specialty, urgency, and missing information, but a qualified human reviewer must approve or reject it before downstream routing. Record policy sources and a concise rationale.",{"source":"RP-GOV-01","specialty":"All"}]
    ]
    Set chunks=kb.AddDocuments(policies)
    Return $$$OK
}

}
