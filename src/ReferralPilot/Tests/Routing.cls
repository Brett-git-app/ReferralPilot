Include %UnitTest

/// Downstream routing tests: only approved referrals become outbound HL7 messages.
Class ReferralPilot.Tests.Routing Extends %UnitTest.TestCase [ ClassType = "", ProcedureBlock ]
{

Method SetUp() As %Status
{
    Kill ^ReferralPilot("ref"), ^ReferralPilot("message"), ^ReferralPilot("audit"), ^ReferralPilot("sequence"), ^ReferralPilot("attempt"), ^ReferralPilot("deadletter"), ^ReferralPilot("alert"), ^ReferralPilot("outbound")
    Return $$$OK
}

Method TearDown() As %Status
{
    Kill ^ReferralPilot("ref"), ^ReferralPilot("message"), ^ReferralPilot("audit"), ^ReferralPilot("sequence"), ^ReferralPilot("attempt"), ^ReferralPilot("deadletter"), ^ReferralPilot("alert"), ^ReferralPilot("outbound")
    Return $$$OK
}

Method CreateReferral(control As %String, code As %String, note As %String) As %String
{
    Set hl7=##class(ReferralPilot.Store).DemoMessage(control,code,note)
    Do ##class(ReferralPilot.Store).CreateFromHL7(hl7,.ref)
    Return ref.id
}

Method HasEvent(id As %String, event As %String) As %Boolean
{
    Set list=##class(ReferralPilot.Store).AuditList(id)
    For i=0:1:list.%Size()-1 {
        Set item=list.%Get(i)
        If item.%Get("event","")=event Return 1
    }
    Return 0
}

Method Approve(id As %String, comment As %String) As %Status
{
    Do ##class(ReferralPilot.Store).RecordRecommendation(id,"Cardiology","SOON","[]","Routed by test.","RP-COMMON-01","replay")
    Return ##class(ReferralPilot.Store).Review(id,"approved","Dr. Routing",comment)
}

Method Route(id As %String) As %Status
{
    Set request=##class(ReferralPilot.RoutingRequest).%New()
    Set request.ReferralID=id
    Set operation=##class(ReferralPilot.RoutingOperation).%New()
    Return operation.OnMessage(request,.response)
}

Method TestApprovedReferralIsRouted() As %Status
{
    Set id=..CreateReferral("MSG-ROUTE-001","CARD","Chest pain on exertion.")
    Do ..Approve(id,"ECG reviewed.")
    Do ..AssertStatusOK(..Route(id),"Routing an approved referral must succeed")
    Do ..AssertTrue($Data(^ReferralPilot("outbound",id))'=0,"An approved referral produces an outbound message")
    Set message=$Get(^ReferralPilot("outbound",id))
    Do ..AssertTrue(message["MSH|^~\&|REFERRALPILOT|IRIS|DOWNSTREAM-CLINIC","The message is addressed to the downstream clinic")
    Do ..AssertTrue(message["OUT-"_id,"MSH-10 carries a routing control id")
    Do ..AssertTrue(message["CARD^Referral accepted","OBR-4 carries the normalized specialty code")
    Do ..AssertTrue(..HasEvent(id,"routing.forwarded"),"The hand-off is written to the audit trail")
    Return $$$OK
}

Method TestUnapprovedReferralIsSkipped() As %Status
{
    Set id=..CreateReferral("MSG-ROUTE-002","CARD","Chest pain on exertion.")
    Do ..AssertStatusOK(..Route(id))
    Do ..AssertEquals(0,$Data(^ReferralPilot("outbound",id)),"A referral without approval is never routed")
    Do ..AssertTrue(..HasEvent(id,"routing.skipped"),"The skip decision is audited")
    Return $$$OK
}

Method TestUnknownReferralRaisesAlert() As %Status
{
    Do ..AssertStatusOK(..Route("NO-SUCH-ID"))
    Set alerts=##class(ReferralPilot.Store).Alerts()
    Do ..AssertEquals(1,alerts.%Size(),"An unknown referral raises one operational alert")
    Return $$$OK
}

Method TestRoutingEscapesFreeText() As %Status
{
    Set id=..CreateReferral("MSG-ROUTE-004","CARD","Chest pain on exertion.")
    Do ..Approve(id,"Reviewed | accepted ^ by cardiology")
    Do ..AssertStatusOK(..Route(id))
    Set message=$Get(^ReferralPilot("outbound",id))
    Do ..AssertTrue(message["NTE|1||Reviewed \F\ accepted \S\ by cardiology","Delimiters in free text use HL7 escapes")
    Return $$$OK
}

Method TestRoutingPreservesPatientIdComponents() As %Status
{
    Set id=..CreateReferral("MSG-ROUTE-005","CARD","Chest pain on exertion.")
    Do ..Approve(id,"Reviewed")
    Do ..AssertStatusOK(..Route(id))
    Set message=$Get(^ReferralPilot("outbound",id))
    Do ..AssertTrue(message["PID|1||SYN-","PID-3 keeps its component hierarchy")
    Do ..AssertTrue(message["^^^DEMO^MR","PID-3 component separators remain intact")
    Return $$$OK
}

}
