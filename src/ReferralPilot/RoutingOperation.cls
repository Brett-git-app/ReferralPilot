Include %occStatus

/// Downstream routing operation. Emits an HL7 v2 ORM^O01 referral acceptance for
/// referrals that a human has approved, and keeps an operator-visible copy on disk.
/// Referrals that are not approved are skipped and audited, never routed.
Class ReferralPilot.RoutingOperation Extends Ens.BusinessOperation
{

/// Folder that receives the outgoing HL7 messages.
Parameter OUTBOUNDDIR = "/tmp/referralpilot-outbound";

/// Receiving application named in MSH-5 of the generated message.
Parameter DESTINATION = "DOWNSTREAM-CLINIC";

Method OnMessage(pRequest As ReferralPilot.RoutingRequest, Output pResponse As Ens.Response) As %Status
{
    Set pResponse=##class(Ens.Response).%New()
    Set id=pRequest.ReferralID
    Set referral=##class(ReferralPilot.Store).Get(id)

    If referral.%Size()=0 {
        Do ##class(ReferralPilot.Store).AddAlert("ReferralPilot.RoutingOperation","Routing requested for unknown referral "_id)
        Return $$$OK
    }
    If referral.status'="approved" {
        Do ##class(ReferralPilot.Store).Audit(id,"system","routing.skipped",{"status":(referral.status)})
        Return $$$OK
    }

    Set message=..BuildMessage(referral)
    Set ^ReferralPilot("outbound",id)=message
    Set file=..WriteFile(id,message)
    Do ##class(ReferralPilot.Store).Audit(id,"system","routing.forwarded",{"destination":(..#DESTINATION),"messageType":"ORM^O01","file":(file)})
    Return $$$OK
}

/// Build the outbound HL7 message from the approved referral state.
Method BuildMessage(referral As %DynamicObject) As %String
{
    Set stamp=$ZDateTime($Horolog,3,1)
    Set id=referral.%Get("id","")
    Set control="OUT-"_id

    Set recommendation=referral.%Get("recommendation",{})
    If '$IsObject(recommendation) Set recommendation={}
    Set review=referral.%Get("review",{})
    If '$IsObject(review) Set review={}

    Set specialty=..SpecialtyCode(recommendation.%Get("specialty","General Medicine"))
    Set comment=review.%Get("comment","")
    If comment="" Set comment="Referral accepted after human review."
    Set note=comment
    Set rationale=recommendation.%Get("rationale","")
    If rationale'="" Set note=note_" Rationale: "_rationale

    Set message="MSH|^~\&|REFERRALPILOT|IRIS|"_..#DESTINATION_"|CLINIC|"_stamp_"||ORM^O01|"_control_"|P|2.5.1"_$C(13)
    Set message=message_"PID|1||"_..EscapeIdentifier(referral.%Get("patientId",""))_"||"_..EscapeIdentifier(referral.%Get("patientLabel",""))_$C(13)
    Set message=message_"PV1|1|O"_$C(13)
    Set message=message_"ORC|NW|"_..EscapeIdentifier(id)_$C(13)
    Set message=message_"OBR|1|"_..EscapeIdentifier(id)_"||"_specialty_"^Referral accepted"_$C(13)
    Set message=message_"NTE|1||"_..Escape(note)_$C(13)
    Return message
}

/// Map the normalized specialty back to the HL7 code the receiving clinic expects.
ClassMethod SpecialtyCode(specialty As %String) As %String
{
    If specialty="Cardiology" Return "CARD"
    If specialty="Neurology" Return "NEURO"
    If specialty="Oncology" Return "ONC"
    If specialty="Orthopedics" Return "ORTHO"
    Return "GENERAL"
}

/// Escape free text using standard HL7 v2 delimiter escape sequences.
ClassMethod Escape(text As %String) As %String
{
    Set text=$Replace(text,$C(13)," ")
    Set text=$Replace(text,$C(10)," ")
    Set text=$Replace(text,"\","\E\")
    Set text=$Replace(text,"|","\F\")
    Set text=$Replace(text,"^","\S\")
    Set text=$Replace(text,"~","\R\")
    Set text=$Replace(text,"&","\T\")
    Return text
}

/// Escape a field while retaining component separators, for identifiers such as PID-3.
ClassMethod EscapeIdentifier(text As %String) As %String
{
    Set text=$Replace(text,$C(13)," ")
    Set text=$Replace(text,$C(10)," ")
    Set text=$Replace(text,"\","\E\")
    Set text=$Replace(text,"|","\F\")
    Set text=$Replace(text,"~","\R\")
    Set text=$Replace(text,"&","\T\")
    Return text
}

/// Persist one outgoing message. A disk failure must not fail the operation.
Method WriteFile(id As %String, message As %String) As %String
{
    Try {
        Set dir=..#OUTBOUNDDIR
        Do ##class(%File).CreateDirectoryChain(dir)
        Set file=##class(%Stream.FileCharacter).%New()
        Set file.Filename=dir_"/"_$Translate(id,"/\:*?<>|","_________")_".hl7"
        Do file.Write(message)
        Do file.%Save()
        Return file.Filename
    } Catch ex {
        Do ##class(ReferralPilot.Store).Audit(id,"system","routing.file_error",{"error":(ex.DisplayString())})
        Return ""
    }
}

}
