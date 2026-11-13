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

Method TestCreateFromHL7Basic() As %Status
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

Method TestCreateFromHL7InvalidPrefix() As %Status
{
    Set sc=##class(ReferralPilot.Store).CreateFromHL7("NOTANHL7",.ref)
    Do ..AssertStatusNotOK(sc,"Should reject non-HL7 payload")
    Return $$$OK
}

Method TestCreateFromHL7MissingMSH10() As %Status
{
    Set hl7="MSH|^~\&|EHR|HOSP|REF|IRIS|202610261200||ORM^O01||P|2.5.1"_$C(13)
    Set sc=##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Do ..AssertStatusNotOK(sc,"Should reject HL7 without MSH-10")
    Return $$$OK
}

Method TestCreateFromHL7RequiresPid() As %Status
{
    Set hl7="MSH|^~\&|EHR|HOSP|REF|IRIS|202610261200||ORM^O01|MSG-NO-PID|P|2.5.1"_$C(13)
        _"OBR|1|MSG-NO-PID||CARD^Cardiology"_$C(13)
        _"NTE|1||Chest pain."_$C(13)
    Set sc=##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Do ..AssertStatusNotOK(sc,"A referral must contain PID-3 patient identity")
    Return $$$OK
}

Method TestCreateFromHL7RequiresNoteSegment() As %Status
{
    Set hl7="MSH|^~\&|EHR|HOSP|REF|IRIS|202610261200||ORM^O01|MSG-NO-NTE|P|2.5.1"_$C(13)
        _"PID|1||PAT-001^^^HOSP^MR||John^Doe"_$C(13)
        _"OBR|1|MSG-NO-NTE||CARD^Cardiology"_$C(13)
    Set sc=##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Do ..AssertStatusNotOK(sc,"A referral must contain an NTE clinical note segment")
    Return $$$OK
}

Method TestCreateRejectsUnsupportedMessageType() As %Status
{
    Set hl7="MSH|^~\&|EHR|HOSP|REF|IRIS|202610261200||ADT^A01|MSG-ADT-001|P|2.5.1"_$C(13)
        _"PID|1||PAT-001^^^HOSP^MR||John^Doe"_$C(13)
        _"OBR|1|MSG-ADT-001||CARD^Cardiology"_$C(13)
        _"NTE|1||Chest pain."_$C(13)
    Set sc=##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Do ..AssertStatusNotOK(sc,"Only ORM^O01 referrals are accepted")
    Return $$$OK
}

Method TestCreateFromHL7Idempotent() As %Status
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

Method TestReplayTriageEscalatesAcuteChestPain() As %Status
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

Method TestReplayTriageExertionalChestPain() As %Status
{
    Set hl7=##class(ReferralPilot.Store).DemoMessage("MSG-EXERT-001","CARD","Chest discomfort on exertion for three weeks.")
    Do ##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Set sc=##class(ReferralPilot.Store).ReplayTriage(ref.id)
    Do ..AssertStatusOK(sc)
    Set result=##class(ReferralPilot.Store).Get(ref.id)
    Do ..AssertEquals("SOON",result.recommendation.urgency,"Exertional chest pain should be SOON")
    Return $$$OK
}

Method TestReplayTriageMissingImaging() As %Status
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

Method TestRecordRecommendationInvalidSpecialty() As %Status
{
    Set hl7=##class(ReferralPilot.Store).DemoMessage("MSG-VAL-001","CARD","Chest pain.")
    Do ##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Set sc=##class(ReferralPilot.Store).RecordRecommendation(ref.id,"Quackery","ROUTINE","[]","Bad","RP-COMMON-01","test")
    Do ..AssertStatusNotOK(sc,"Invalid specialty should be rejected")
    Return $$$OK
}

Method TestRecordRecommendationInvalidUrgency() As %Status
{
    Set hl7=##class(ReferralPilot.Store).DemoMessage("MSG-VAL-002","CARD","Chest pain.")
    Do ##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Set sc=##class(ReferralPilot.Store).RecordRecommendation(ref.id,"Cardiology","MAYBE","[]","Bad","RP-COMMON-01","test")
    Do ..AssertStatusNotOK(sc,"Invalid urgency should be rejected")
    Return $$$OK
}

Method TestRecordRecommendationNoSuchReferral() As %Status
{
    Set sc=##class(ReferralPilot.Store).RecordRecommendation("NO-SUCH-ID","Cardiology","ROUTINE","[]","x","RP-COMMON-01","test")
    Do ..AssertStatusNotOK(sc,"Missing referral id should error")
    Return $$$OK
}

Method TestRecordRecommendationOverridesUrgencySafety() As %Status
{
    Set hl7=##class(ReferralPilot.Store).DemoMessage("MSG-SAFETY-001","CARD","Acute chest pain, diaphoresis, breathlessness at rest.")
    Do ##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Set sc=##class(ReferralPilot.Store).RecordRecommendation(ref.id,"Cardiology","ROUTINE","[]","x","RP-COMMON-01","test")
    Do ..AssertStatusOK(sc,"Should accept recommendation even with ROUTINE")
    Set result=##class(ReferralPilot.Store).Get(ref.id)
    Do ..AssertEquals("URGENT",result.recommendation.urgency,"Safety override must escalate ROUTINE to URGENT for acute symptoms")
    Return $$$OK
}

Method TestReviewApproved() As %Status
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

Method TestReviewRejected() As %Status
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

Method TestReviewAcceptsCaseInsensitiveDecision() As %Status
{
    Set hl7=##class(ReferralPilot.Store).DemoMessage("MSG-REV-CASE-001","CARD","Chest pain.")
    Do ##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Do ##class(ReferralPilot.Store).ReplayTriage(ref.id)
    Set sc=##class(ReferralPilot.Store).Review(ref.id,"APPROVED","Dr. Case","Validated")
    Do ..AssertStatusOK(sc,"Decision values should be normalized")
    Set result=##class(ReferralPilot.Store).Get(ref.id)
    Do ..AssertEquals("approved",result.status)
    Return $$$OK
}

Method TestReviewDecisionIsFinal() As %Status
{
    Set hl7=##class(ReferralPilot.Store).DemoMessage("MSG-REV-FINAL-001","CARD","Chest pain.")
    Do ##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Do ##class(ReferralPilot.Store).ReplayTriage(ref.id)
    Do ##class(ReferralPilot.Store).Review(ref.id,"approved","Dr. Final","Approved")
    Set secondSc=##class(ReferralPilot.Store).Review(ref.id,"rejected","Dr. Final","Rejected later")
    Do ..AssertStatusNotOK(secondSc,"A finalized review cannot be overwritten")
    Set stored=##class(ReferralPilot.Store).Get(ref.id)
    Do ..AssertEquals("approved",stored.status)
    Return $$$OK
}

Method TestNeedsInformationApprovalRequiresComment() As %Status
{
    Set hl7=##class(ReferralPilot.Store).DemoMessage("MSG-REV-MISSING-001","NEURO","Progressive headaches. Imaging report is not attached.")
    Do ##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Do ##class(ReferralPilot.Store).ReplayTriage(ref.id)
    Set sc=##class(ReferralPilot.Store).Review(ref.id,"approved","Dr. Safety","")
    Do ..AssertStatusNotOK(sc,"Approval with missing information needs a documented comment")
    Set sc=##class(ReferralPilot.Store).Review(ref.id,"approved","Dr. Safety","Proceeding with an explicit documented exception.")
    Do ..AssertStatusOK(sc)
    Return $$$OK
}

Method TestApprovedReferralCannotBeRetriaged() As %Status
{
    Set hl7=##class(ReferralPilot.Store).DemoMessage("MSG-STATE-001","CARD","Chest pain.")
    Do ##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Do ##class(ReferralPilot.Store).ReplayTriage(ref.id)
    Do ##class(ReferralPilot.Store).Review(ref.id,"approved","Dr. State","Approved")
    Set sc=##class(ReferralPilot.Store).ReplayTriage(ref.id)
    Do ..AssertStatusNotOK(sc,"An approved recommendation must not be overwritten by triage")
    Set result=##class(ReferralPilot.Store).Get(ref.id)
    Do ..AssertEquals("approved",result.status,"Rejected triage must not change the workflow state")
    Return $$$OK
}

Method TestTriageStartStateGuard() As %Status
{
    Do ..AssertTrue(##class(ReferralPilot.Store).CanStartTriage("received"),"A received referral may start triage")
    Do ..AssertFalse(##class(ReferralPilot.Store).CanStartTriage("pending_review"),"A pending referral may not be triaged again")
    Do ..AssertFalse(##class(ReferralPilot.Store).CanStartTriage("approved"),"An approved referral may not be triaged again")
    Do ..AssertFalse(##class(ReferralPilot.Store).CanStartTriage("rejected"),"A rejected referral may not be triaged again")
    Return $$$OK
}

Method TestTriageClaimIsSingleUse() As %Status
{
    Set hl7=##class(ReferralPilot.Store).DemoMessage("MSG-CLAIM-001","CARD","Chest pain.")
    Do ##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Set sc=##class(ReferralPilot.Store).ClaimTriage(ref.id,.claimed)
    Do ..AssertStatusOK(sc,"The first triage claim should succeed")
    Do ..AssertEquals("triage_queued",claimed.status)
    Set secondSc=##class(ReferralPilot.Store).ClaimTriage(ref.id,.secondClaim)
    Do ..AssertStatusNotOK(secondSc,"A queued referral cannot be claimed twice")
    Return $$$OK
}

Method TestTriageReleaseRestoresPriorStatus() As %Status
{
    Set hl7=##class(ReferralPilot.Store).DemoMessage("MSG-CLAIM-002","CARD","Chest pain.")
    Do ##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Do ##class(ReferralPilot.Store).ClaimTriage(ref.id,.claimed)
    Set sc=##class(ReferralPilot.Store).ReleaseTriageClaim(ref.id,"queue unavailable")
    Do ..AssertStatusOK(sc,"Releasing a triage claim should succeed")
    Set stored=##class(ReferralPilot.Store).Get(ref.id)
    Do ..AssertEquals("received",stored.status,"Queue failure restores the original status")
    Do ..AssertEquals("queue unavailable",stored.lastError)
    Return $$$OK
}

Method TestReviewBadDecision() As %Status
{
    Set hl7=##class(ReferralPilot.Store).DemoMessage("MSG-REV-003","CARD","Chest pain.")
    Do ##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Do ##class(ReferralPilot.Store).ReplayTriage(ref.id)
    Set sc=##class(ReferralPilot.Store).Review(ref.id,"maybe","Dr. X","")
    Do ..AssertStatusNotOK(sc,"Only approved/rejected are valid decisions")
    Return $$$OK
}

Method TestReviewNotPending() As %Status
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

Method TestGetNotFound() As %Status
{
    Set result=##class(ReferralPilot.Store).Get("NO-SUCH-REFERRAL")
    Do ..AssertEquals(0,result.%Size(),"Unknown referral should return empty object")
    Return $$$OK
}

Method TestGetByIdAuditIncluded() As %Status
{
    Set hl7=##class(ReferralPilot.Store).DemoMessage("MSG-GET-001","CARD","Chest pain.")
    Do ##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Set result=##class(ReferralPilot.Store).Get(ref.id)
    Do ..AssertTrue($IsObject(result.audit),"Get() should include audit array")
    Return $$$OK
}

Method TestOutboundMissing() As %Status
{
    Set result=##class(ReferralPilot.Store).Outbound("NO-SUCH-ID")
    Do ..AssertEquals(0,result.%Size(),"Unknown outbound messages should return an empty object")
    Return $$$OK
}

}
