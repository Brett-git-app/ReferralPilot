Include %UnitTest

/// Unit tests for ReferralPilot.Agent — replay fallback and error paths.
Class ReferralPilot.Tests.Agent Extends %UnitTest.TestCase [ ClassType = "", ProcedureBlock ]
{

Method SetUp() As %Status
{
    Kill ^ReferralPilot("ref"), ^ReferralPilot("message"), ^ReferralPilot("audit"), ^ReferralPilot("sequence")
    Return $$$OK
}

Method TearDown() As %Status
{
    Kill ^ReferralPilot("ref"), ^ReferralPilot("message"), ^ReferralPilot("audit"), ^ReferralPilot("sequence")
    Return $$$OK
}

Method TestIsDemoMode_ReturnsBoolean() As %Status
{
    // IsDemoMode reads REFERRALPILOT_DEMO_MODE from the environment.
    // We only assert it returns $$$TRUE or $$$FALSE (no setter exists in IRIS).
    Set val=##class(ReferralPilot.Agent).IsDemoMode()
    Do ..AssertTrue((val=$$$TRUE)||(val=$$$FALSE),"IsDemoMode must return a boolean")
    Return $$$OK
}

Method TestRun_UnknownReferral() As %Status
{
    Set result=##class(ReferralPilot.Agent).Run("NO-SUCH-ID")
    Do ..AssertEquals("Referral not found",result.%Get("error",""))
    Return $$$OK
}

Method TestRun_ProducesReplayRecommendation() As %Status
{
    // Agent.Run either does live AI Hub call (needs network + key) or falls back to replay.
    // This test exercises the full path by ensuring a recommendation is always recorded.
    Set hl7=##class(ReferralPilot.Store).DemoMessage("MSG-AGENT-001","CARD","Chest pain on exertion.")
    Do ##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Set result=##class(ReferralPilot.Agent).Run(ref.id)
    Do ..AssertEquals("completed",result.%Get("status",""),"Agent.Run must complete")
    Do ..AssertTrue(("replay"=result.%Get("mode",""))||("live"=result.%Get("mode",""))||("replay-fallback"=result.%Get("mode","")),"Mode must be replay, live, or replay-fallback")
    // A recommendation should now be stored regardless of mode.
    Set stored=##class(ReferralPilot.Store).Get(ref.id)
    Do ..AssertTrue($IsObject(stored.recommendation),"Stored referral should have a recommendation object after triage")
    Do ..AssertTrue(stored.recommendation.%Get("specialty","")'="","Recommendation must have a specialty")
    Return $$$OK
}

Method TestRun_ProducesAuditEntry() As %Status
{
    Set hl7=##class(ReferralPilot.Store).DemoMessage("MSG-AGENT-002","NEURO","Headache imaging missing.")
    Do ##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Do ##class(ReferralPilot.Agent).Run(ref.id)
    Set stored=##class(ReferralPilot.Store).Get(ref.id)
    Do ..AssertTrue(stored.audit.%Size()>=2,"Agent Run should produce at least 2 audit entries (received + triage event)")
    Return $$$OK
}

}
