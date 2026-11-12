Include %occStatus

/// Bounded AI Hub tools: read-only lookup plus a validated pending recommendation write.
Class ReferralPilot.Tools Extends %AI.Tool
{

/// Search the bundled policy set when the vector embedding model is unavailable.
Method SearchPolicies(referralID As %String, query As %String) As %DynamicArray
{
    Set q=$ZConvert(query,"L"), result=[]
    If (q["chest")!(q["cardiac")!(q["ecg")!(q["cardiology") {
        Do result.%Push({"source":"RP-CARD-01","text":"Cardiology referrals include symptom duration, severity, ECG when available, and cardiac history. Acute chest pain with diaphoresis, syncope, or breathlessness at rest needs urgent same-day clinical escalation."})
    }
    If (q["headache")!(q["imaging")!(q["neurology") {
        Do result.%Push({"source":"RP-NEURO-02","text":"Progressive headache referrals should include onset, progression, neurological red flags, and imaging report. If imaging is missing, request it and keep pending review."})
    }
    Do result.%Push({"source":"RP-COMMON-01","text":"Never invent missing facts. List missing items explicitly and keep the recommendation for human review."})
    Do ##class(ReferralPilot.Store).Audit(referralID,"agent","tool.policy_fallback",{"matches":(result.%Size())})
    Return result
}

/// Read the clinic's synthetic capacity and service note. Capacity must never change clinical urgency.
Method GetClinicCapacity(referralID As %String, specialty As %String) As %DynamicObject
{
    Set specialty=##class(ReferralPilot.Store).NormalizeSpecialty(specialty)
    Set free=$Select(specialty="Cardiology":2,specialty="Neurology":0,specialty="Oncology":1,specialty="Orthopedics":3,1:4)
    Set clinicNote=$Select(free>0:"Synthetic capacity only; clinician confirms scheduling.",1:"No synthetic slots this week; coordinate an alternate clinic. Never downgrade urgency.")
    Set result={"specialty":(specialty),"availableSlotsThisWeek":(free),"clinicNote":(clinicNote)}
    Do ##class(ReferralPilot.Store).Audit(referralID,"agent","tool.capacity",result)
    Return result
}

/// Record a recommendation for human review. This tool cannot approve or route a referral.
Method RecordRecommendation(referralID As %String, specialty As %String, urgency As %String, missingJSON As %String, rationale As %String, policySource As %String) As %String
{
    Set sc=##class(ReferralPilot.Store).RecordRecommendation(referralID,specialty,urgency,missingJSON,rationale,policySource,"live")
    If $$$ISERR(sc) $$$ThrowStatus(sc)
    Return "Recommendation saved as pending human review. No downstream routing has occurred."
}

}
