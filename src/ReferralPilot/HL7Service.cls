Include %occStatus

/// Inbound HL7 v2 service. Watches a drop folder for referral messages, validates
/// them with the deterministic parser, and queues the AI triage business process.
/// The service is transport-only: it never interprets clinical content itself.
Class ReferralPilot.HL7Service Extends Ens.BusinessService
{

Parameter ADAPTER = "Ens.InboundAdapter";

/// Drop folder monitored for inbound HL7 v2 referral files.
Parameter INBOUNDDIR = "/tmp/referralpilot-inbound";

/// Folder for files that were consumed or rejected, so nothing is silently lost.
Parameter ARCHIVEDIR = "/tmp/referralpilot-inbound/consumed";

/// Configuration item that runs the AI triage business process.
Parameter TRIAGETARGET = "TriageProcess";

/// Poll interval in seconds is supplied by the adapter's CallInterval setting.
Method OnTask() As %Status
{
    Try {
        Do ..Poll()
    } Catch ex {
        Do ##class(ReferralPilot.Store).AddAlert("ReferralPilot.HL7Service","Inbound poll failed: "_ex.DisplayString())
    }
    Return $$$OK
}

/// Scan the drop folder once and ingest every .hl7 file.
Method Poll() As %Status
{
    Set dir=..#INBOUNDDIR
    If '##class(%File).DirectoryExists(dir) Do ##class(%File).CreateDirectoryChain(dir)

    Set stmt=##class(%SQL.Statement).%New()
    Set sc=stmt.%PrepareClassQuery("%File","FileSet")
    If $$$ISERR(sc) {
        Do ##class(ReferralPilot.Store).AddAlert("ReferralPilot.HL7Service","Inbound folder listing is unavailable: "_$System.Status.GetErrorText(sc))
        Return $$$OK
    }
    Set rs=stmt.%Execute(dir,"*.hl7")
    While rs.%Next() {
        Set path=rs.%GetData(1)
        If path="" Continue
        Do ..Ingest(path)
    }
    Return $$$OK
}

/// Ingest one HL7 file: read it, validate it, archive it, and queue triage.
Method Ingest(path As %String) As %Status
{
    If '##class(%File).Exists(path) Return $$$OK

    Set raw=""
    Try {
        Set stream=##class(%Stream.FileCharacter).%New()
        Set sc=stream.LinkToFile(path)
        If $$$ISERR(sc) {
            Do ##class(ReferralPilot.Store).AddAlert("ReferralPilot.HL7Service","Cannot read "_path_": "_$System.Status.GetErrorText(sc))
            Do ..Archive(path,"bad")
            Return $$$OK
        }
        // In this IRIS build Size is a property of %Stream, not a method.
        Set raw=stream.Read(stream.Size)
    } Catch ex {
        Do ##class(ReferralPilot.Store).AddAlert("ReferralPilot.HL7Service","Unreadable HL7 file "_path_": "_ex.DisplayString())
        Do ..Archive(path,"bad")
        Return $$$OK
    }

    Do ..Archive(path)

    // Normalize CR, LF, and CRLF terminators before reading MSH-10 for duplicate detection.
    Set raw=$Replace(raw,$C(13,10),$C(13))
    Set raw=$Replace(raw,$C(10),$C(13))
    Set control=$Piece($Piece(raw,$C(13),1),"|",10), duplicate=0
    If control'="" Set duplicate=$Data(^ReferralPilot("message",control))

    Set sc=##class(ReferralPilot.Store).CreateFromHL7(raw,.referral)
    If $$$ISERR(sc) {
        Do ##class(ReferralPilot.Store).AddAlert("ReferralPilot.HL7Service","Rejected HL7 file "_$Piece(path,"/",*)_": "_$System.Status.GetErrorText(sc))
        Return $$$OK
    }

    If duplicate {
        Do ##class(ReferralPilot.Store).Audit(referral.id,"system","hl7.duplicate_ignored",{"file":($Piece(path,"/",*))})
        Return $$$OK
    }

    Do ##class(ReferralPilot.Store).Audit(referral.id,"system","hl7.service_ingested",{"file":($Piece(path,"/",*)),"messageControlId":(referral.messageControlId)})
    Set sc=##class(ReferralPilot.Store).ClaimTriage(referral.id,.claimed,0,"hl7-service")
    If $$$ISERR(sc) {
        Do ##class(ReferralPilot.Store).AddAlert("ReferralPilot.HL7Service","Triage claim failed for "_referral.id_": "_$System.Status.GetErrorText(sc))
        Return $$$OK
    }
    Set request=##class(ReferralPilot.TriageRequest).%New()
    Set request.ReferralID=referral.id
    Set sc=..SendRequestAsync(..#TRIAGETARGET,request)
    If $$$ISERR(sc) {
        Set detail=$System.Status.GetErrorText(sc)
        Do ##class(ReferralPilot.Store).ReleaseTriageClaim(referral.id,detail)
        Do ##class(ReferralPilot.Store).AddAlert("ReferralPilot.HL7Service","Triage not queued for "_referral.id_": "_detail)
    }
    Return $$$OK
}

/// Move a consumed file out of the drop folder so it is not ingested twice.
/// Files that cannot be read are archived with a "bad" suffix so a single
/// malformed file never causes an endless retry loop.
Method Archive(path As %String, suffix As %String = "") As %Status
{
    Set archive=..#ARCHIVEDIR
    If '##class(%File).DirectoryExists(archive) Do ##class(%File).CreateDirectoryChain(archive)
    Set stamp=$Translate($ZDateTime($Horolog,3,1),": -","___")
    Set name=$Piece(path,"/",*)
    If suffix'="" Set name=name_"."_suffix
    Set newPath=archive_"/"_name_"-"_stamp_".hl7"
    Do ##class(%File).Rename(path,newPath)
    Return $$$OK
}

}
