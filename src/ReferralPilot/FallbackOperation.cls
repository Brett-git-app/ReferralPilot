Include %occStatus

/// Exception handling operation: parks a failed referral, writes a dead letter, and raises an alert.
/// This operation never retries the agent; it only hands the referral to a human.
Class ReferralPilot.FallbackOperation Extends Ens.BusinessOperation
{

/// Dead-letter directory. Configurable per production item; the default is container-local
/// so the demo has no external dependency.
Property DeadLetterDir As %String(MAXLEN = 200) [ InitialExpression = "/tmp/referralpilot-deadletter" ];

/// Expose the directory in the Management Portal as a Basic setting.
Parameter SETTINGS = "DeadLetterDir:Basic";

Method OnMessage(pRequest As ReferralPilot.FallbackRequest, Output pResponse As Ens.Response) As %Status
{
    Set pResponse=##class(Ens.Response).%New()
    Set id=pRequest.ReferralID
    Set reason=pRequest.Reason
    If reason="" Set reason="Automated triage failed without a diagnostic message"
    Set attempts=pRequest.Attempts

    Do ##class(ReferralPilot.Store).AddDeadLetter(id,reason,attempts)
    Do ##class(ReferralPilot.Store).RequestManualTriage(id,reason,attempts)
    Do ##class(ReferralPilot.Store).AddAlert(pRequest.Source,"Referral "_id_" needs manual triage after "_attempts_" automated attempt(s). Reason: "_reason)
    Do ..WriteDeadLetterFile(id,reason,attempts)
    Return $$$OK
}

/// File-system dead letter so an operator can pick the message up outside IRIS.
/// Failures here must not break the fallback, so the write is best effort.
Method WriteDeadLetterFile(id As %String, reason As %String, attempts As %Integer) As %Status
{
    Try {
        Set dir=..DeadLetterDir
        If dir="" Set dir="/tmp/referralpilot-deadletter"
        Do ##class(%File).CreateDirectoryChain(dir)
        Set safe=$Translate(id,"/\:*?<>|","_________")
        Set payload={"id":(id),"reason":(reason),"attempts":(attempts),"at":($ZDateTime($Horolog,3,1))}
        Set file=##class(%Stream.FileCharacter).%New()
        Set file.Filename=dir_"/"_safe_"-"_$Horolog_".json"
        Do file.Write(payload.%ToJSON())
        Do file.%Save()
    } Catch ex {
        Do ##class(ReferralPilot.Store).Audit(id,"system","pipeline.dead_letter_file_error",{"error":(ex.DisplayString())})
    }
    Return $$$OK
}

}
