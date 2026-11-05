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
  <Route Url="/referrals/{id}" Method="GET" Call="GetById" />
  <Route Url="/referrals/{id}/triage" Method="POST" Call="TriageById" />
  <Route Url="/referrals/{id}/approve" Method="POST" Call="ApproveById" />
  <Route Url="/referrals/{id}/reject" Method="POST" Call="RejectById" />
  <Route Url="/referrals/{id}/retry" Method="POST" Call="RetryById" />
  <Route Url="/referrals/{id}/manual-triage" Method="POST" Call="ManualTriageById" />
  <Route Url="/pipeline" Method="GET" Call="Pipeline" />
  <Route Url="/deadletters" Method="GET" Call="DeadLetters" />
  <Route Url="/alerts" Method="GET" Call="Alerts" />
  <Route Url="/hl7" Method="POST" Call="Receive" />
  <Route Url="/triage" Method="POST" Call="Triage" />
  <Route Url="/review" Method="POST" Call="Review" />
  <Route Url="/demo/reset" Method="POST" Call="Reset" />
</Routes>
}

ClassMethod Health() As %Status
{
    Set demoMode=$ZConvert($System.Util.GetEnviron("REFERRALPILOT_DEMO_MODE"),"U")="TRUE"
    Set apiKey=$System.Util.GetEnviron("OPENAI_API_KEY")
    Set kbStatus=##class(ReferralPilot.Knowledge).GetKBStatus()
    Do ..JSON(200,{"ready":1,"application":"ReferralPilot","irisNamespace":"IRISAPP","agentKeyConfigured":(apiKey'=""),"demoMode":demoMode,"knowledgeBase":kbStatus})
    Return $$$OK
}

ClassMethod List() As %Status
{
    Do ..JSON(200,##class(ReferralPilot.Store).List())
    Return $$$OK
}

ClassMethod GetById(id As %String) As %Status
{
    Set referral=##class(ReferralPilot.Store).Get(id)
    If referral.%Size()=0 {
        Do ..JSON(404,{"error":"Referral not found"})
        Return $$$OK
    }
    Do ..JSON(200,referral)
    Return $$$OK
}

ClassMethod Receive() As %Status
{
    Set body=%request.Content.Read()
    Set sc=##class(ReferralPilot.Store).CreateFromHL7(body,.referral)
    If $$$ISERR(sc) {
        Do ..JSON(400,{"error":$System.Status.GetErrorText(sc)})
        Return $$$OK
    }
    Do ..JSON(201,referral)
    Return $$$OK
}

ClassMethod Triage() As %Status
{
    Set body={}.%FromJSON(%request.Content)
    If '$IsObject(body)!(body.%Get("id","")="") {
        Do ..JSON(400,{"error":"JSON body must include a referral id"})
        Return $$$OK
    }
    Do ..RunTriage(body.id)
    Return $$$OK
}

ClassMethod TriageById(id As %String) As %Status
{
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
    Set request=##class(ReferralPilot.TriageRequest).%New()
    Set request.ReferralID=id
    Set sc=##class(Ens.Director).SendRequestAsync("ReferralPilot.Production.TriageProcess",request)
    If $$$ISERR(sc) {
        Do ..JSON(503,{"error":"Could not queue the triage request. Confirm ReferralPilot.Production is running.","detail":$System.Status.GetErrorText(sc)})
        Return $$$OK
    }
    Do ..JSON(202,{"status":"queued","id":(id),"workflow":"ReferralPilot.Production"})
    Return $$$OK
}

ClassMethod Review() As %Status
{
    Set body={}.%FromJSON(%request.Content)
    If '$IsObject(body)!(body.%Get("id","")="")!(body.%Get("decision","")="") {
        Do ..JSON(400,{"error":"JSON body must include id and decision"})
        Return $$$OK
    }
    Set reviewer=body.%Get("reviewer","Demo Reviewer")
    Set comment=body.%Get("comment","")
    Set sc=##class(ReferralPilot.Store).Review(body.id,body.decision,reviewer,comment)
    If $$$ISERR(sc) {
        Do ..JSON(409,{"error":$System.Status.GetErrorText(sc)})
        Return $$$OK
    }
    If body.decision="approved" Do ..RouteApproval(body.id)
    Do ..JSON(200,##class(ReferralPilot.Store).Get(body.id))
    Return $$$OK
}

ClassMethod ApproveById(id As %String) As %Status
{
    Set comment="", body={}
    Try { Set body={}.%FromJSON(%request.Content), comment=body.%Get("comment","") } Catch {}
    Set reviewer=body.%Get("reviewer","Demo Reviewer")
    Set sc=##class(ReferralPilot.Store).Review(id,"approved",reviewer,comment)
    If $$$ISERR(sc) {
        Do ..JSON(409,{"error":$System.Status.GetErrorText(sc)})
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
    Set request=##class(ReferralPilot.RoutingRequest).%New()
    Set request.ReferralID=id
    Set sc=##class(Ens.Director).SendRequestAsync("ReferralPilot.Production.RoutingOperation",request)
    If $$$ISERR(sc) {
        Do ##class(ReferralPilot.Store).AddAlert("ReferralPilot.API","Downstream routing not queued for "_id_": "_$System.Status.GetErrorText(sc))
        Do ##class(ReferralPilot.Store).Audit(id,"system","routing.queue_failed",{"detail":($System.Status.GetErrorText(sc))})
    }
    Return $$$OK
}

ClassMethod RejectById(id As %String) As %Status
{
    Set comment="", body={}
    Try { Set body={}.%FromJSON(%request.Content), comment=body.%Get("comment","") } Catch {}
    Set reviewer=body.%Get("reviewer","Demo Reviewer")
    Set sc=##class(ReferralPilot.Store).Review(id,"rejected",reviewer,comment)
    If $$$ISERR(sc) {
        Do ..JSON(409,{"error":$System.Status.GetErrorText(sc)})
        Return $$$OK
    }
    Do ..JSON(200,##class(ReferralPilot.Store).Get(id))
    Return $$$OK
}

ClassMethod Reset() As %Status
{
    Set sc=##class(ReferralPilot.Store).ResetDemo()
    If $$$ISERR(sc) {
        Do ..JSON(500,{"error":$System.Status.GetErrorText(sc)})
        Return $$$OK
    }
    Do ..JSON(200,{"loaded":3,"referrals":##class(ReferralPilot.Store).List()})
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
ClassMethod RetryById(id As %String) As %Status
{
    Set referral=##class(ReferralPilot.Store).Get(id)
    If referral.%Size()=0 {
        Do ..JSON(404,{"error":"Referral not found"})
        Return $$$OK
    }
    If (referral.status'="triage_retrying")&(referral.status'="manual_triage_required") {
        Do ..JSON(409,{"error":"Only a retrying or manually parked referral can be retried"})
        Return $$$OK
    }
    Do ##class(ReferralPilot.Store).ClearAttempts(id)
    Do ##class(ReferralPilot.Store).Audit(id,"system","pipeline.retry_requested",{"source":"api"})
    Set request=##class(ReferralPilot.TriageRequest).%New()
    Set request.ReferralID=id
    Set sc=##class(Ens.Director).SendRequestAsync("ReferralPilot.Production.TriageProcess",request)
    If $$$ISERR(sc) {
        Do ..JSON(503,{"error":"Could not queue the triage request. Confirm ReferralPilot.Production is running.","detail":$System.Status.GetErrorText(sc)})
        Return $$$OK
    }
    Do ..JSON(202,{"status":"queued","id":(id),"attemptsReset":1})
    Return $$$OK
}

/// Human fallback: a reviewer completes the triage the automated pipeline could not finish.
ClassMethod ManualTriageById(id As %String) As %Status
{
    Set referral=##class(ReferralPilot.Store).Get(id)
    If referral.%Size()=0 {
        Do ..JSON(404,{"error":"Referral not found"})
        Return $$$OK
    }
    If referral.status'="manual_triage_required" {
        Do ..JSON(409,{"error":"Only a referral parked by the pipeline fallback can be triaged manually"})
        Return $$$OK
    }
    Set body={}
    Try { Set body={}.%FromJSON(%request.Content) } Catch {}
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
        Do ..JSON(409,{"error":$System.Status.GetErrorText(sc)})
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
    Do %response.Write(value.%ToJSON())
    Return $$$OK
}

}
