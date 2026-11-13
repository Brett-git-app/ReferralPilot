Include %UnitTest

/// Exception handling and human-fallback pipeline tests.
Class ReferralPilot.Tests.Pipeline Extends %UnitTest.TestCase [ ClassType = "", ProcedureBlock ]
{

Method SetUp() As %Status
{
    Kill ^ReferralPilot("ref"), ^ReferralPilot("message"), ^ReferralPilot("audit"), ^ReferralPilot("sequence"), ^ReferralPilot("attempt"), ^ReferralPilot("deadletter"), ^ReferralPilot("alert")
    Return $$$OK
}

Method TearDown() As %Status
{
    Kill ^ReferralPilot("ref"), ^ReferralPilot("message"), ^ReferralPilot("audit"), ^ReferralPilot("sequence"), ^ReferralPilot("attempt"), ^ReferralPilot("deadletter"), ^ReferralPilot("alert")
    Return $$$OK
}

Method CreateReferral(control As %String, code As %String, note As %String) As %String
{
    Set hl7=##class(ReferralPilot.Store).DemoMessage(control,code,note)
    Do ##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Return ref.id
}

Method TestAttemptCounterAndClear() As %Status
{
    Set id=..CreateReferral("MSG-PIPE-001","CARD","Chest pain on exertion.")
    Do ..AssertEquals(0,##class(ReferralPilot.Store).Attempts(id),"A new referral starts with zero attempts")
    Do ..AssertEquals(1,##class(ReferralPilot.Store).RecordAttempt(id,"first failure"))
    Do ..AssertEquals(2,##class(ReferralPilot.Store).RecordAttempt(id,"second failure"))
    Set stored=##class(ReferralPilot.Store).Get(id)
    Do ..AssertEquals("triage_retrying",stored.status,"A failed attempt parks the referral in triage_retrying")
    Do ##class(ReferralPilot.Store).ClearAttempts(id)
    Do ..AssertEquals(0,##class(ReferralPilot.Store).Attempts(id),"ClearAttempts resets the counter")
    Return $$$OK
}

Method TestFallbackOperationRoutesToHumanQueue() As %Status
{
    Set id=..CreateReferral("MSG-PIPE-002","NEURO","Progressive headaches, imaging not attached.")
    Set request=##class(ReferralPilot.FallbackRequest).%New()
    Set request.ReferralID=id, request.Reason="model provider unavailable", request.Attempts=3, request.Source="ReferralPilot.Tests"
    Set operation=##class(ReferralPilot.FallbackOperation).%New()
    Set sc=operation.OnMessage(request,.response)
    Do ..AssertStatusOK(sc,"Fallback operation must always succeed so the referral is never lost")
    Set stored=##class(ReferralPilot.Store).Get(id)
    Do ..AssertEquals("manual_triage_required",stored.status,"Exhausted automation hands the referral to the manual queue")
    Do ..AssertEquals("model provider unavailable",stored.lastError)
    Set letters=##class(ReferralPilot.Store).DeadLetters()
    Do ..AssertEquals(1,letters.%Size(),"One dead letter per fallback")
    Set alerts=##class(ReferralPilot.Store).Alerts()
    Do ..AssertEquals(1,alerts.%Size(),"One alert per fallback")
    Return $$$OK
}

Method TestManualTriageCompletesFallback() As %Status
{
    Set id=..CreateReferral("MSG-PIPE-003","CARD","Chest discomfort on exertion for three weeks.")
    Do ##class(ReferralPilot.Store).RequestManualTriage(id,"agent failed three times",3)
    Set stored=##class(ReferralPilot.Store).Get(id)
    Do ..AssertEquals("manual_triage_required",stored.status)
    Do ..AssertEquals(3,stored.fallback.attempts,"Fallback records how many attempts failed")
    Set sc=##class(ReferralPilot.Store).ManualTriage(id,"Cardiology","SOON","[]","Human reviewer completed triage after pipeline fallback.","Dr. Fallback")
    Do ..AssertStatusOK(sc,"Manual triage should succeed on a parked referral")
    Set stored=##class(ReferralPilot.Store).Get(id)
    Do ..AssertEquals("pending_review",stored.status,"Manual triage returns the referral to human review")
    Do ..AssertEquals("manual",stored.mode)
    Do ..AssertEquals("Cardiology",stored.recommendation.specialty)
    Do ..AssertEquals("Dr. Fallback",stored.manualReview.reviewer)
    Return $$$OK
}

Method TestManualTriageKeepsSafetyEscalation() As %Status
{
    Set id=..CreateReferral("MSG-PIPE-004","CARD","Acute chest pain, diaphoresis and breathlessness at rest.")
    Do ##class(ReferralPilot.Store).RequestManualTriage(id,"agent failed",3)
    Set sc=##class(ReferralPilot.Store).ManualTriage(id,"Cardiology","ROUTINE","[]","Reviewer selected ROUTINE.","Dr. Fallback")
    Do ..AssertStatusOK(sc)
    Set stored=##class(ReferralPilot.Store).Get(id)
    Do ..AssertEquals("URGENT",stored.recommendation.urgency,"Safety escalation also applies to human-entered triage")
    Return $$$OK
}

Method TestManualTriageRejectsUnknownSpecialty() As %Status
{
    Set id=..CreateReferral("MSG-PIPE-005","CARD","Chest pain.")
    Do ##class(ReferralPilot.Store).RequestManualTriage(id,"agent failed",3)
    Set sc=##class(ReferralPilot.Store).ManualTriage(id,"Quackery","ROUTINE","[]","Bad specialty","Dr. Fallback")
    Do ..AssertStatusNotOK(sc,"Unknown specialty must be rejected on the manual path too")
    Return $$$OK
}

Method TestReviewAfterManualTriage() As %Status
{
    Set id=..CreateReferral("MSG-PIPE-006","CARD","Chest pain on exertion.")
    Do ##class(ReferralPilot.Store).RequestManualTriage(id,"agent failed",3)
    Do ##class(ReferralPilot.Store).ManualTriage(id,"Cardiology","SOON","[]","Manual triage","Dr. Fallback")
    Set sc=##class(ReferralPilot.Store).Review(id,"approved","Dr. Chief","Approved after manual triage.")
    Do ..AssertStatusOK(sc,"A manually triaged referral still needs the review gate")
    Set stored=##class(ReferralPilot.Store).Get(id)
    Do ..AssertEquals("approved",stored.status)
    Return $$$OK
}

Method TestPipelineStats() As %Status
{
    Set first=..CreateReferral("MSG-PIPE-010","CARD","Chest pain on exertion.")
    Set second=..CreateReferral("MSG-PIPE-011","NEURO","Progressive headaches.")
    Do ##class(ReferralPilot.Store).RecordAttempt(second,"provider timeout")
    Do ##class(ReferralPilot.Store).RequestManualTriage(second,"provider timeout",3)
    Do ##class(ReferralPilot.Store).AddDeadLetter(second,"provider timeout",3)
    Do ##class(ReferralPilot.Store).AddAlert("ReferralPilot.Tests","test alert")
    Set stats=##class(ReferralPilot.Store).PipelineStats()
    Do ..AssertEquals(2,stats.total,"Pipeline counts every referral")
    Do ..AssertEquals(1,stats.manualQueue,"Pipeline counts the manual queue")
    Do ..AssertEquals(1,stats.deadLetters,"Pipeline counts dead letters")
    Do ..AssertEquals(1,stats.alerts,"Pipeline counts alerts")
    Do ..AssertEquals(1,stats.attemptsRecorded,"Pipeline sums failed attempts")
    Return $$$OK
}

Method TestManualTriageOnMissingReferral() As %Status
{
    Set sc=##class(ReferralPilot.Store).ManualTriage("NO-SUCH-ID","Cardiology","ROUTINE","[]","x","Dr. X")
    Do ..AssertStatusNotOK(sc,"Manual triage must reject an unknown referral")
    Return $$$OK
}

}
