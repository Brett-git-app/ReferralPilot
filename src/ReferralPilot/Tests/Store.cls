Include %UnitTest

/// Unit tests for ReferralPilot.Store — HL7 parsing, replay triage, urgency rules, review workflow.
Class ReferralPilot.Tests.Store Extends %UnitTest.TestCase [ ClassType = "", ProcedureBlock ]
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

Method TestResetDemo() As %Status
{
    Set sc=##class(ReferralPilot.Store).ResetDemo()
    Do ..AssertStatusOK(sc,"ResetDemo should succeed")
    Set list=##class(ReferralPilot.Store).List()
    Do ..AssertEquals(3,list.%Size(),"Demo should load 3 referrals")
    Return $$$OK
}

Method TestCreateFromHL7_Basic() As %Status
{
    Set hl7="MSH|^~\&|EHR|HOSP|REF|IRIS|202610261200||ORM^O01|MSG-001|P|2.5.1"_$C(13)
        _"PID|1||PAT-001^^^HOSP^MR||John^Doe||19750505|M"_$C(13)
        _"PV1|1|O"_$C(13)
        _"ORC|NW|MSG-001"_$C(13)
        _"OBR|1|MSG-001||CARD^Cardiology"_$C(13)
        _"NTE|1||Chest pain on exertion."_$C(13)
    Set sc=##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Do ..AssertStatusOK(sc,"HL7 parse should succeed")
    Do ..AssertEquals("MSG-001",ref.messageControlId,"MessageControlId must be extracted from MSH-10")
    Do ..AssertEquals("Cardiology",ref.requestedSpecialty,"Specialty CARD should normalize to Cardiology")
    Do ..AssertEquals("received",ref.status,"New referral should have status=received")
    Do ..AssertTrue($IsObject(ref.recommendation),"recommendation should be an object")
    Do ..AssertEquals("pending",ref.mode,"Mode should be pending before triage")
    Do ..AssertEquals("Chest pain on exertion.",ref.clinicalNote,"Note should be extracted from NTE")
    Return $$$OK
}

Method TestCreateFromHL7_InvalidPrefix() As %Status
{
    Set sc=##class(ReferralPilot.Store).CreateFromHL7("NOTANHL7",.ref)
    Do ..AssertStatusNotOK(sc,"Should reject non-HL7 payload")
    Return $$$OK
}

Method TestCreateFromHL7_MissingMSH10() As %Status
{
    Set hl7="MSH|^~\&|EHR|HOSP|REF|IRIS|202610261200||ORM^O01||P|2.5.1"_$C(13)
    Set sc=##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Do ..AssertStatusNotOK(sc,"Should reject HL7 without MSH-10")
    Return $$$OK
}

Method TestCreateFromHL7_Idempotent() As %Status
{
    Set hl7=##class(ReferralPilot.Store).DemoMessage("MSG-DEMO-001","CARD","Exertional chest pain.")
    Set sc1=##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref1)
    Do ..AssertStatusOK(sc1)
    Set firstId=ref1.id
    Set sc2=##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref2)
    Do ..AssertStatusOK(sc2)
    Do ..AssertEquals(firstId,ref2.id,"Same MSH-10 must return the same referral id (idempotent)")
    Return $$$OK
}

Method TestNormalizeSpecialty() As %Status
{
    Do ..AssertEquals("Cardiology",##class(ReferralPilot.Store).NormalizeSpecialty("CARD"))
    Do ..AssertEquals("Cardiology",##class(ReferralPilot.Store).NormalizeSpecialty("cardio"))
    Do ..AssertEquals("Neurology",##class(ReferralPilot.Store).NormalizeSpecialty("NEURO"))
    Do ..AssertEquals("Oncology",##class(ReferralPilot.Store).NormalizeSpecialty("oncology"))
    Do ..AssertEquals("Orthopedics",##class(ReferralPilot.Store).NormalizeSpecialty("ortho"))
    Do ..AssertEquals("General Medicine",##class(ReferralPilot.Store).NormalizeSpecialty("UNKNOWN"))
    Return $$$OK
}

Method TestReplayTriage_EscalatesAcuteChestPain() As %Status
{
    Set hl7=##class(ReferralPilot.Store).DemoMessage("MSG-ACUTE-001","CARD","Acute chest pain with diaphoresis and breathlessness at rest.")
    Do ##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Set sc=##class(ReferralPilot.Store).ReplayTriage(ref.id)
    Do ..AssertStatusOK(sc,"ReplayTriage should succeed")
    Set result=##class(ReferralPilot.Store).Get(ref.id)
    Do ..AssertEquals("URGENT",result.recommendation.urgency,"Acute chest pain must escalate to URGENT")
    Do ..AssertEquals("replay",result.mode,"Mode should be replay")
    Return $$$OK
}

Method TestReplayTriage_ExertionalChestPain() As %Status
{
    Set hl7=##class(ReferralPilot.Store).DemoMessage("MSG-EXERT-001","CARD","Chest discomfort on exertion for three weeks.")
    Do ##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Set sc=##class(ReferralPilot.Store).ReplayTriage(ref.id)
    Do ..AssertStatusOK(sc)
    Set result=##class(ReferralPilot.Store).Get(ref.id)
    Do ..AssertEquals("SOON",result.recommendation.urgency,"Exertional chest pain should be SOON")
    Return $$$OK
}

Method TestReplayTriage_MissingImaging() As %Status
{
    Set hl7=##class(ReferralPilot.Store).DemoMessage("MSG-IMAGING-001","NEURO","Progressive headaches. Imaging report is not attached.")
    Do ##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Set sc=##class(ReferralPilot.Store).ReplayTriage(ref.id)
    Do ..AssertStatusOK(sc)
    Set result=##class(ReferralPilot.Store).Get(ref.id)
    Do ..AssertEquals("needs_information",result.status,"Missing imaging must set status to needs_information")
    Do ..AssertTrue(result.recommendation.missingInformation.%Size()>0,"Should have missing info items")
    Return $$$OK
}

Method TestRecordRecommendation_InvalidSpecialty() As %Status
{
    Set hl7=##class(ReferralPilot.Store).DemoMessage("MSG-VAL-001","CARD","Chest pain.")
    Do ##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Set sc=##class(ReferralPilot.Store).RecordRecommendation(ref.id,"Quackery","ROUTINE","[]","Bad","RP-COMMON-01","test")
    Do ..AssertStatusNotOK(sc,"Invalid specialty should be rejected")
    Return $$$OK
}

Method TestRecordRecommendation_InvalidUrgency() As %Status
{
    Set hl7=##class(ReferralPilot.Store).DemoMessage("MSG-VAL-002","CARD","Chest pain.")
    Do ##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Set sc=##class(ReferralPilot.Store).RecordRecommendation(ref.id,"Cardiology","MAYBE","[]","Bad","RP-COMMON-01","test")
    Do ..AssertStatusNotOK(sc,"Invalid urgency should be rejected")
    Return $$$OK
}

Method TestRecordRecommendation_NoSuchReferral() As %Status
{
    Set sc=##class(ReferralPilot.Store).RecordRecommendation("NO-SUCH-ID","Cardiology","ROUTINE","[]","x","RP-COMMON-01","test")
    Do ..AssertStatusNotOK(sc,"Missing referral id should error")
    Return $$$OK
}

Method TestRecordRecommendation_OverridesUrgencySafety() As %Status
{
    Set hl7=##class(ReferralPilot.Store).DemoMessage("MSG-SAFETY-001","CARD","Acute chest pain, diaphoresis, breathlessness at rest.")
    Do ##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Set sc=##class(ReferralPilot.Store).RecordRecommendation(ref.id,"Cardiology","ROUTINE","[]","x","RP-COMMON-01","test")
    Do ..AssertStatusOK(sc,"Should accept recommendation even with ROUTINE")
    Set result=##class(ReferralPilot.Store).Get(ref.id)
    Do ..AssertEquals("URGENT",result.recommendation.urgency,"Safety override must escalate ROUTINE to URGENT for acute symptoms")
    Return $$$OK
}

Method TestReview_Approved() As %Status
{
    Set hl7=##class(ReferralPilot.Store).DemoMessage("MSG-REV-001","CARD","Chest pain.")
    Do ##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Do ##class(ReferralPilot.Store).ReplayTriage(ref.id)
    Set sc=##class(ReferralPilot.Store).Review(ref.id,"approved","Dr. Smith","Looks good.")
    Do ..AssertStatusOK(sc)
    Set result=##class(ReferralPilot.Store).Get(ref.id)
    Do ..AssertEquals("approved",result.status,"Status should be approved")
    Do ..AssertEquals("Dr. Smith",result.review.reviewer,"Reviewer should be recorded")
    Return $$$OK
}

Method TestReview_Rejected() As %Status
{
    Set hl7=##class(ReferralPilot.Store).DemoMessage("MSG-REV-002","CARD","Chest pain.")
    Do ##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Do ##class(ReferralPilot.Store).ReplayTriage(ref.id)
    Set sc=##class(ReferralPilot.Store).Review(ref.id,"rejected","Dr. Jones","Wrong specialty.")
    Do ..AssertStatusOK(sc)
    Set result=##class(ReferralPilot.Store).Get(ref.id)
    Do ..AssertEquals("rejected",result.status)
    Return $$$OK
}

Method TestReview_BadDecision() As %Status
{
    Set hl7=##class(ReferralPilot.Store).DemoMessage("MSG-REV-003","CARD","Chest pain.")
    Do ##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Do ##class(ReferralPilot.Store).ReplayTriage(ref.id)
    Set sc=##class(ReferralPilot.Store).Review(ref.id,"maybe","Dr. X","")
    Do ..AssertStatusNotOK(sc,"Only approved/rejected are valid decisions")
    Return $$$OK
}

Method TestReview_NotPending() As %Status
{
    Set hl7=##class(ReferralPilot.Store).DemoMessage("MSG-REV-004","CARD","Chest pain.")
    Do ##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Set sc=##class(ReferralPilot.Store).Review(ref.id,"approved","Dr. X","")
    Do ..AssertStatusNotOK(sc,"Cannot review before triage (no pending recommendation)")
    Return $$$OK
}

Method TestAuditTrail() As %Status
{
    Set hl7=##class(ReferralPilot.Store).DemoMessage("MSG-AUDIT-001","CARD","Chest pain.")
    Do ##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Do ##class(ReferralPilot.Store).ReplayTriage(ref.id)
    Do ##class(ReferralPilot.Store).Review(ref.id,"approved","Dr. A","ok")
    Set list=##class(ReferralPilot.Store).AuditList(ref.id)
    Do ..AssertTrue(list.%Size()>=3,"Audit trail should have at least 3 events (received, recommended, reviewed)")
    Set first=list.%Get(0)
    Do ..AssertEquals("hl7.received",first.event,"First event should be hl7.received")
    Return $$$OK
}

Method TestGet_NotFound() As %Status
{
    Set result=##class(ReferralPilot.Store).Get("NO-SUCH-REFERRAL")
    Do ..AssertEquals(0,result.%Size(),"Unknown referral should return empty object")
    Return $$$OK
}

Method TestGetById_AuditIncluded() As %Status
{
    Set hl7=##class(ReferralPilot.Store).DemoMessage("MSG-GET-001","CARD","Chest pain.")
    Do ##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Set result=##class(ReferralPilot.Store).Get(ref.id)
    Do ..AssertTrue($IsObject(result.audit),"Get() should include audit array")
    Return $$$OK
}

}
