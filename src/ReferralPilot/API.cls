Include %occStatus

/// JSON API for HL7 intake, triage, reviewer actions, and workflow inspection.
Class ReferralPilot.API Extends %CSP.REST
{

Parameter CONTENTTYPE = "application/json";

XData UrlMap [ XMLNamespace = "http://www.intersystems.com/urlmap" ]
{
<Routes>
  <Route Url="/health" Method="GET" Call="Health" />
  <Route Url="/referrals" Method="GET" Call="List" />
  <Route Url="/referral" Method="GET" Call="GetById" />
  <Route Url="/outbound" Method="GET" Call="OutboundById" />
  <Route Url="/triageById" Method="POST" Call="TriageById" />
  <Route Url="/approve" Method="POST" Call="ApproveById" />
  <Route Url="/reject" Method="POST" Call="RejectById" />
  <Route Url="/retry" Method="POST" Call="RetryById" />
  <Route Url="/manual-triage" Method="POST" Call="ManualTriageById" />
  <Route Url="/pipeline" Method="GET" Call="Pipeline" />
  <Route Url="/deadletters" Method="GET" Call="DeadLetters" />
  <Route Url="/alerts" Method="GET" Call="Alerts" />
  <Route Url="/hl7" Method="POST" Call="Receive" />
  <Route Url="/triage" Method="POST" Call="Triage" />
  <Route Url="/review" Method="POST" Call="Review" />
  <Route Url="/demo/reset" Method="POST" Call="Reset" />
</Routes>
}

/// Enforce an optional shared API token while keeping /health public for probes.
ClassMethod OnPreDispatch(pUrl As %String, pMethod As %String, ByRef pContinue As %Boolean) As %Status
{
    Set pContinue=1
    Do %response.SetHeader("X-Content-Type-Options","nosniff")
    Do %response.SetHeader("X-Frame-Options","DENY")
    Do %response.SetHeader("Referrer-Policy","no-referrer")
    If pMethod="OPTIONS" Return $$$OK
    Set expected=$System.Util.GetEnviron("REFERRALPILOT_API_TOKEN")
    If expected="" Return $$$OK
    If (pUrl="/health")!(pUrl="/health/") Return $$$OK
    Set supplied=%request.GetHeader("X-ReferralPilot-Token")
    If supplied=expected Return $$$OK
    Set pContinue=0
    Do ..JSON(401,{"error":"Unauthorized. Supply X-ReferralPilot-Token."})
    Return $$$OK
}

/// Read an optional JSON object body. Empty bodies are valid for endpoints
/// whose fields are all optional, while malformed JSON is rejected consistently.
ClassMethod ReadJsonBody(Output body As %DynamicObject) As %Status
{
    Set body={}
    Set raw=%request.Content.Read()
    If $ZStrip(raw,"<>W")="" Return $$$OK
    Try {
        Set body={}.%FromJSON(raw)
    } Catch ex {
        Return $$$ERROR($$$GeneralError,"Request body must be a JSON object")
    }
    If '$IsObject(body)!($ClassName(body)'="%Library.DynamicObject") {
        Return $$$ERROR($$$GeneralError,"Request body must be a JSON object")
    }
    Return $$$OK
}

ClassMethod Health() As %Status
{
    Set demoMode=$ZConvert($System.Util.GetEnviron("REFERRALPILOT_DEMO_MODE"),"U")="TRUE"
    Set apiKey=$System.Util.GetEnviron("OPENAI_API_KEY")
    Set agentKeyConfigured=(apiKey'="")
    Set apiTokenRequired=($System.Util.GetEnviron("REFERRALPILOT_API_TOKEN")'="")
    Set reviewerRequired=##class(ReferralPilot.Store).ReviewerRequired()
    Set kbStatus=##class(ReferralPilot.Knowledge).GetKBStatus()
    Do ..JSON(200,{"ready":1,"application":"ReferralPilot","irisNamespace":"IRISAPP","agentKeyConfigured":(agentKeyConfigured),"apiTokenRequired":(apiTokenRequired),"reviewerIdentityRequired":(reviewerRequired),"demoMode":(demoMode),"knowledgeBase":(kbStatus)})
    Return $$$OK
}

ClassMethod List() As %Status
{
    Do ..JSON(200,##class(ReferralPilot.Store).List())
    Return $$$OK
}

ClassMethod GetById(id As %String = "") As %Status
{
    If id="" Set id=%request.Get("id")
    Set referral=##class(ReferralPilot.Store).Get(id)
    If referral.%Size()=0 {
        Do ..JSON(404,{"error":"Referral not found"})
        Return $$$OK
    }
    Do ..JSON(200,referral)
    Return $$$OK
}

ClassMethod OutboundById(id As %String = "") As %Status
{
    If id="" Set id=%request.Get("id")
    Set outbound=##class(ReferralPilot.Store).Outbound(id)
    If outbound.%Size()=0 {
        Do ..JSON(404,{"error":"No downstream message has been routed for this referral"})
        Return $$$OK
    }
    Do ..JSON(200,outbound)
    Return $$$OK
}

ClassMethod Receive() As %Status
{
    Set body=%request.Content.Read(1048577)
    If $Length(body)>1048576 {
        Do ..JSON(413,{"error":"HL7 message exceeds the 1 MiB limit"})
        Return $$$OK
    }
    Set sc=##class(ReferralPilot.Store).CreateFromHL7(body,.referral)
    If $$$ISERR(sc) {
        Do ..JSON(400,{"error":($System.Status.GetErrorText(sc))})
        Return $$$OK
    }
    Do ..JSON(201,referral)
    Return $$$OK
}

ClassMethod Triage() As %Status
{
    Set sc=..ReadJsonBody(.body)
    If $$$ISERR(sc) {
        Do ..JSON(400,{"error":"Request body must be a JSON object"})
        Return $$$OK
    }
    If '$IsObject(body)!(body.%Get("id","")="") {
        Do ..JSON(400,{"error":"JSON body must include a referral id"})
        Return $$$OK
    }
    Do ..RunTriage(body.id)
    Return $$$OK
}

ClassMethod TriageById(id As %String = "") As %Status
{
    If id="" Set id=%request.Get("id")
    Do ..RunTriage(id)
    Return $$$OK
}

ClassMethod RunTriage(id As %String) As %Status
{
    Set referral=##class(ReferralPilot.Store).Get(id)
    If referral.%Size()=0 {
        Do ..JSON(404,{"error":"Referral not found"})
        Return $$$OK
    }
    If '##class(ReferralPilot.Store).CanStartTriage(referral.status) {
        Do ..JSON(409,{"error":"Triage can only start for a received referral","status":(referral.status)})
        Return $$$OK
    }
    Set sc=##class(ReferralPilot.Store).ClaimTriage(id,.claimed,0,"api")
    If $$$ISERR(sc) {
        Do ..JSON(409,{"error":($System.Status.GetErrorText(sc))})
        Return $$$OK
    }
    Set sc=..DispatchTriage(id)
    If $$$ISERR(sc) {
        Set detail=$System.Status.GetErrorText(sc)
        Do ##class(ReferralPilot.Store).ReleaseTriageClaim(id,detail)
        Do ..JSON(503,{"error":"Could not run the triage request.","detail":(detail)})
        Return $$$OK
    }
    Do ##class(ReferralPilot.Store).Audit(id,"system","pipeline.triage_queued",{"source":"api"})
    Do ..JSON(202,{"status":"queued","id":(id),"workflow":"ReferralPilot.TriageProcess"})
    Return $$$OK
}

/// Run the triage business process in-process. IRIS 2027.1 no longer exposes
/// Ens.Director.SendRequestAsync and hosts cannot be instantiated outside a
/// production, so the process logic is invoked as a class method.
ClassMethod DispatchTriage(id As %String) As %Status
{
    Return ##class(ReferralPilot.TriageProcess).Execute(id)
}

ClassMethod Review() As %Status
{
    Set sc=..ReadJsonBody(.body)
    If $$$ISERR(sc) {
        Do ..JSON(400,{"error":"Request body must be a JSON object"})
        Return $$$OK
    }
    If '$IsObject(body)!(body.%Get("id","")="")!(body.%Get("decision","")="") {
        Do ..JSON(400,{"error":"JSON body must include id and decision"})
        Return $$$OK
    }
    Set reviewer=body.%Get("reviewer","Demo Reviewer")
    Set comment=body.%Get("comment","")
    Set sc=##class(ReferralPilot.Store).Review(body.id,body.decision,reviewer,comment)
    If $$$ISERR(sc) {
        Do ..JSON(409,{"error":($System.Status.GetErrorText(sc))})
        Return $$$OK
    }
    If $ZConvert(body.decision,"L")="approved" Do ..RouteApproval(body.id)
    Do ..JSON(200,##class(ReferralPilot.Store).Get(body.id))
    Return $$$OK
}

ClassMethod ApproveById(id As %String = "") As %Status
{
    Set sc=..ReadJsonBody(.body)
    If $$$ISERR(sc) {
        Do ..JSON(400,{"error":"Request body must be a JSON object"})
        Return $$$OK
    }
    If id="" Set id=body.%Get("id","")
    If id="" Set id=%request.Get("id")
    Set comment=body.%Get("comment","")
    Set reviewer=body.%Get("reviewer","Demo Reviewer")
    Set sc=##class(ReferralPilot.Store).Review(id,"approved",reviewer,comment)
    If $$$ISERR(sc) {
        Do ..JSON(409,{"error":($System.Status.GetErrorText(sc))})
        Return $$$OK
    }
    Do ..RouteApproval(id)
    Do ..JSON(200,##class(ReferralPilot.Store).Get(id))
    Return $$$OK
}

/// Queue the downstream HL7 routing operation after a human approval.
/// Routing is best effort: a messaging failure raises an alert and is audited,
/// but it never rolls back the approval the clinician already made.
ClassMethod RouteApproval(id As %String) As %Status
{
    Set sc=##class(ReferralPilot.RoutingOperation).Route(id)
    If $$$ISERR(sc) {
        Do ##class(ReferralPilot.Store).AddAlert("ReferralPilot.API","Downstream routing not queued for "_id_": "_($System.Status.GetErrorText(sc)))
        Do ##class(ReferralPilot.Store).Audit(id,"system","routing.queue_failed",{"detail":($System.Status.GetErrorText(sc))})
    }
    Return $$$OK
}

ClassMethod RejectById(id As %String = "") As %Status
{
    Set sc=..ReadJsonBody(.body)
    If $$$ISERR(sc) {
        Do ..JSON(400,{"error":"Request body must be a JSON object"})
        Return $$$OK
    }
    If id="" Set id=body.%Get("id","")
    If id="" Set id=%request.Get("id")
    Set comment=body.%Get("comment","")
    Set reviewer=body.%Get("reviewer","Demo Reviewer")
    Set sc=##class(ReferralPilot.Store).Review(id,"rejected",reviewer,comment)
    If $$$ISERR(sc) {
        Do ..JSON(409,{"error":($System.Status.GetErrorText(sc))})
        Return $$$OK
    }
    Do ..JSON(200,##class(ReferralPilot.Store).Get(id))
    Return $$$OK
}

ClassMethod Reset() As %Status
{
    If '##class(ReferralPilot.Store).DemoResetAllowed() {
        Do ..JSON(403,{"error":"Demo reset is disabled. Set REFERRALPILOT_ALLOW_DEMO_RESET=true only for an isolated test environment."})
        Return $$$OK
    }
    Set sc=##class(ReferralPilot.Store).ResetDemo()
    If $$$ISERR(sc) {
        Do ..JSON(500,{"error":($System.Status.GetErrorText(sc))})
        Return $$$OK
    }
    Set list=##class(ReferralPilot.Store).List()
    Do ..JSON(200,{"loaded":3,"referrals":(list)})
    Return $$$OK
}

ClassMethod Pipeline() As %Status
{
    Do ..JSON(200,##class(ReferralPilot.Store).PipelineStats())
    Return $$$OK
}

ClassMethod DeadLetters() As %Status
{
    Set items=##class(ReferralPilot.Store).DeadLetters()
    Do ..JSON(200,{"count":(items.%Size()),"items":(items)})
    Return $$$OK
}

ClassMethod Alerts() As %Status
{
    Set items=##class(ReferralPilot.Store).Alerts()
    Do ..JSON(200,{"count":(items.%Size()),"items":(items)})
    Return $$$OK
}

/// Human-triggered retry: clears the attempt counter and queues triage again.
ClassMethod RetryById(id As %String = "") As %Status
{
    If id="" Set id=%request.Get("id")
    Set referral=##class(ReferralPilot.Store).Get(id)
    If referral.%Size()=0 {
        Do ..JSON(404,{"error":"Referral not found"})
        Return $$$OK
    }
    Set sc=##class(ReferralPilot.Store).ClaimTriage(id,.claimed,1,"retry")
    If $$$ISERR(sc) {
        Do ..JSON(409,{"error":($System.Status.GetErrorText(sc))})
        Return $$$OK
    }
    Do ##class(ReferralPilot.Store).ClearAttempts(id)
    Do ##class(ReferralPilot.Store).Audit(id,"system","pipeline.retry_requested",{"source":"api"})
    Set sc=..DispatchTriage(id)
    If $$$ISERR(sc) {
        Set detail=$System.Status.GetErrorText(sc)
        Do ##class(ReferralPilot.Store).ReleaseTriageClaim(id,detail)
        Do ..JSON(503,{"error":"Could not run the triage request.","detail":(detail)})
        Return $$$OK
    }
    Do ..JSON(202,{"status":"queued","id":(id),"attemptsReset":1})
    Return $$$OK
}

/// Human fallback: a reviewer completes the triage the automated pipeline could not finish.
ClassMethod ManualTriageById(id As %String = "") As %Status
{
    If id="" Set id=%request.Get("id")
    Set referral=##class(ReferralPilot.Store).Get(id)
    If referral.%Size()=0 {
        Do ..JSON(404,{"error":"Referral not found"})
        Return $$$OK
    }
    If referral.status'="manual_triage_required" {
        Do ..JSON(409,{"error":"Only a referral parked by the pipeline fallback can be triaged manually"})
        Return $$$OK
    }
    Set sc=..ReadJsonBody(.body)
    If $$$ISERR(sc) {
        Do ..JSON(400,{"error":"Request body must be a JSON object"})
        Return $$$OK
    }
    Set specialty=body.%Get("specialty",""), urgency=body.%Get("urgency","")
    If (specialty="")!(urgency="") {
        Do ..JSON(400,{"error":"JSON body must include specialty and urgency"})
        Return $$$OK
    }
    Set missing=body.%Get("missingInformation",[])
    If '$IsObject(missing) Set missing=[]
    Set rationale=body.%Get("rationale","Manual triage completed by a human reviewer after automated fallback.")
    Set reviewer=body.%Get("reviewer","Demo Reviewer")
    Set sc=##class(ReferralPilot.Store).ManualTriage(id,specialty,urgency,missing.%ToJSON(),rationale,reviewer)
    If $$$ISERR(sc) {
        Do ..JSON(409,{"error":($System.Status.GetErrorText(sc))})
        Return $$$OK
    }
    Do ..JSON(200,##class(ReferralPilot.Store).Get(id))
    Return $$$OK
}

ClassMethod JSON(code As %Integer, value As %DynamicAbstractObject) As %Status
{
    Set %response.Status=code
    Set %response.ContentType="application/json; charset=utf-8"
    Do %response.SetHeader("Cache-Control","no-store")
    // Guard the write so an oversized or malformed payload returns a bounded
    // error instead of a raw ObjectScript stack error.
    Try {
        Write value.%ToJSON()
    } Catch ex {
        Write "{""error"":""Response could not be serialised"",""detail"":"""_$Translate(ex.DisplayString(),"""""","''")_"""}"
    }
    Return $$$OK
}

}
