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
    Set id=pRequest.ReferralID
    Set attempts=##class(ReferralPilot.Store).Attempts(id)
    Set done=0, lastError=""

    While (attempts<..#MAXATTEMPTS) {
        Set attempts=attempts+1, ok=0, result={}
        Try {
            Set result=##class(ReferralPilot.Agent).Run(id)
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

    Set sc=..SendRequestSync(..#FALLBACKTARGET,fallback,.fbResponse)
    If $$$ISERR(sc) {
        // Last resort: persist the fallback inline so a lost operation never loses a referral.
        Do ##class(ReferralPilot.Store).AddDeadLetter(id,lastError,..#MAXATTEMPTS)
        Do ##class(ReferralPilot.Store).RequestManualTriage(id,lastError,..#MAXATTEMPTS)
        Do ##class(ReferralPilot.Store).AddAlert("ReferralPilot.TriageProcess","Fallback operation unavailable for referral "_id_". Reason: "_lastError)
    }
    Return $$$OK
}

}
