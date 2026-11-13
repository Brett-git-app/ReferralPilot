Include %occStatus

/// Referral decision agent. It proposes; only a reviewer can approve.
Class ReferralPilot.Agent Extends %AI.Agent
{

Parameter MODEL = "gpt-5-nano";

XData INSTRUCTIONS [ MimeType = text/markdown ]
{
# ReferralPilot triage agent

You help a clinician review a synthetic referral. You do not diagnose, prescribe, or make a final care decision.

For each referral:
1. Search the referral policy knowledge base before recommending. If vector retrieval is not available, use SearchPolicies.
2. Call GetClinicCapacity for the requested specialty.
3. Compare the clinical note to the policy. Never invent facts. Flag missing information explicitly.
4. Call RecordRecommendation exactly once with a concise rationale, evidence policy source ID(s), specialty, urgency, and missing-information JSON array.
5. Keep urgency values to ROUTINE, SOON, URGENT, or EMERGENCY. Call GetClinicCapacity with both the referral ID and requested specialty. The recommendation tool records it as pending review and cannot approve it.
6. Mention that a human reviewer must confirm the decision. If the note suggests immediate danger, advise urgent human assessment without claiming a diagnosis.
}

Method %OnInit() As %Status
{
    Set key=$System.Util.GetEnviron("OPENAI_API_KEY")
    If key="" Return $$$ERROR($$$GeneralError,"OPENAI_API_KEY is not configured")
    Set ..Provider=##class(%AI.Provider).Create("openai",{"api_key":(key)})
    Set model=$System.Util.GetEnviron("REFERRALPILOT_MODEL")
    If model'="" Set ..Model=model
    Set sc=..ToolManager.AddTool(##class(ReferralPilot.Tools).%New())
    If $$$ISERR(sc) Return sc
    Set sc=##class(ReferralPilot.Knowledge).BuildKB(.kb)
    If $$$ISOK(sc) {
        Set sc=kb.AddToAgent($THIS)
        If $$$ISERR(sc) Return sc
    }
    Return $$$OK
}

ClassMethod IsDemoMode() As %Boolean
{
    Return ($ZConvert($System.Util.GetEnviron("REFERRALPILOT_DEMO_MODE"),"U")="TRUE")
}

ClassMethod Triage(id As %String) As %DynamicObject
{
    Set referral=##class(ReferralPilot.Store).Get(id)
    If referral.%Size()=0 Return {"error":"Referral not found"}
    If ..IsDemoMode() {
        Do ##class(ReferralPilot.Store).Audit(id,"system","triage.demo_mode",{"note":"REFERRALPILOT_DEMO_MODE=true; deterministic replay used."})
        Return {"mode":"replay","status":"completed","sc":(##class(ReferralPilot.Store).ReplayTriage(id))}
    }
    Set key=$System.Util.GetEnviron("OPENAI_API_KEY")
    If key="" Return {"mode":"replay","status":"completed","sc":(##class(ReferralPilot.Store).ReplayTriage(id))}
    Try {
        Set agent=..%New()
        $$$ThrowOnError(agent.%Init())
        Set session=agent.CreateSession()
        Set prompt="Triage this HL7 referral. ID="_id_". Requested specialty="_referral.requestedSpecialty_". Clinical note="_referral.clinicalNote_". Search relevant policies using the vector knowledge base or SearchPolicies, call GetClinicCapacity with referralID="_id_" and the specialty, then record your pending recommendation with the tools. Return a concise reviewer-facing summary."
        Set response=agent.Chat(session,prompt)
        Set stats=session.GetStats()
        Do ##class(ReferralPilot.Store).Audit(id,"agent","agent.completed",{"summary":(response.Content),"toolCalls":(stats.%Get("total_tool_calls",0)),"promptTokens":(stats.%Get("total_prompt_tokens",0)),"completionTokens":(stats.%Get("total_completion_tokens",0))})
        Set current=##class(ReferralPilot.Store).Get(id)
        If current.recommendation.%Get("specialty","")="" {
            Do ##class(ReferralPilot.Store).Audit(id,"system","agent.no_recommendation",{"note":"Agent response did not record a recommendation; deterministic replay used."})
            Set sc=##class(ReferralPilot.Store).ReplayTriage(id)
            Return {"mode":"replay-fallback","status":"completed","summary":"The model did not call the recommendation tool. Deterministic replay was used and remains pending human review.","stats":(stats)}
        }
        Return {"mode":"live","status":"completed","summary":(response.Content),"stats":(stats)}
    } Catch ex {
        Do ##class(ReferralPilot.Store).Audit(id,"system","agent.error",{"error":(ex.DisplayString())})
        Return {"mode":"live","status":"error","error":(ex.DisplayString())}
    }
}

}
