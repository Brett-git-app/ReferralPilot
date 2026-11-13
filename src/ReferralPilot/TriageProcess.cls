Include %occStatus

/// Interoperability business process: runs the agent with bounded retries,
/// then hands the referral to the human fallback pipeline when automation is exhausted.
Class ReferralPilot.TriageProcess Extends Ens.BusinessProcess
{

/// Automatic attempts allowed before the referral is parked for manual triage.
Parameter MAXATTEMPTS = 3;

/// Configuration item that receives ReferralPilot.FallbackRequest messages.
Parameter FALLBACKTARGET = "FallbackOperation";

Method OnRequest(pRequest As ReferralPilot.TriageRequest, Output pResponse As Ens.Response) As %Status
{
    Set pResponse=##class(Ens.Response).%New()
    Return ..Execute(pRequest.ReferralID,$THIS)
}

/// Run the triage loop for one referral. pProcess is the live business process
/// instance when the call comes from the production; when the REST API drives
/// triage directly it is empty and the fallback is applied inline.
ClassMethod Execute(id As %String, pProcess = "") As %Status
{
    Set referral=##class(ReferralPilot.Store).Get(id)
    If referral.%Size()=0 Return $$$OK
    If (referral.status'="triage_queued")&(referral.status'="triage_retrying") {
        Do ##class(ReferralPilot.Store).Audit(id,"system","pipeline.request_ignored",{"status":(referral.status)})
        Return $$$OK
    }
    Set attempts=##class(ReferralPilot.Store).Attempts(id)
    Set done=0, lastError=""

    While (attempts<..#MAXATTEMPTS) {
        Set attempts=attempts+1, ok=0, result={}
        Try {
            Set result=##class(ReferralPilot.Agent).Triage(id)
            If result.%Get("status","")="error" {
                Set lastError=result.%Get("error","AI triage failed"), ok=0
            } Else {
                Set ok=1
            }
        } Catch ex {
            Set lastError=ex.DisplayString()
        }
        If ok {
            Do ##class(ReferralPilot.Store).ClearAttempts(id)
            Set done=1
            Quit
        }
        Do ##class(ReferralPilot.Store).RecordAttempt(id,lastError)
    }

    If done Return $$$OK

    // Automated path exhausted. Route to the human fallback operation.
    Set fallback=##class(ReferralPilot.FallbackRequest).%New()
    Set fallback.ReferralID=id
    Set fallback.Reason=lastError
    Set fallback.Attempts=..#MAXATTEMPTS
    Set fallback.Source="ReferralPilot.TriageProcess"

    Set sc=$$$ERROR($$$GeneralError,"Fallback operation is only reachable inside the production")
    If $ISOBJECT(pProcess) {
        Try {
            Set sc=$METHOD(pProcess,"SendRequestSync",..#FALLBACKTARGET,fallback,.fbResponse)
        } Catch ex {
            Set sc=$$$ERROR($$$GeneralError,ex.DisplayString())
        }
    }
    If $$$ISERR(sc) {
        // Last resort: persist the fallback inline so a lost operation never loses a referral.
        Do ##class(ReferralPilot.Store).AddDeadLetter(id,lastError,..#MAXATTEMPTS)
        Do ##class(ReferralPilot.Store).RequestManualTriage(id,lastError,..#MAXATTEMPTS)
        Do ##class(ReferralPilot.Store).AddAlert("ReferralPilot.TriageProcess","Fallback operation unavailable for referral "_id_". Reason: "_lastError)
    }
    Return $$$OK
}

}
