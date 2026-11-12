Include %occStatus

/// Durable demo workflow state. Original HL7 payloads and audit events are kept in IRIS globals.
Class ReferralPilot.Store Extends %RegisteredObject
{

/// Triage may start only for a newly received referral. Failed or parked
/// referrals use their explicit retry/manual paths.
ClassMethod CanStartTriage(status As %String) As %Boolean
{
    Return status="received"
}

/// Atomically claim a referral for asynchronous triage. This closes the race
/// where two API requests could both queue the same referral.
ClassMethod ClaimTriage(id As %String, Output referral As %DynamicObject, allowRetry As %Boolean = 0, source As %String = "api") As %Status
{
    Set sc=$$$OK
    Lock +^ReferralPilot("claim",id):5
    If '$Test Return $$$ERROR($$$GeneralError,"Referral is busy")
    Try {
        Set referral=..Get(id)
        If referral.%Size()=0 {
            Set sc=$$$ERROR($$$GeneralError,"Referral not found")
        } Else {
            Set previousStatus=referral.status
            If 'allowRetry,('previousStatus'="received") {
                Set sc=$$$ERROR($$$GeneralError,"Triage can only start for a received referral")
            } ElseIf allowRetry,('$Find(",triage_retrying,manual_triage_required,",","_previousStatus_",")) {
                Set sc=$$$ERROR($$$GeneralError,"Only a retrying or manually parked referral can be retried")
            } Else {
                Set referral.status="triage_queued", referral.triagePreviousStatus=previousStatus
                Do referral.%Remove("audit")
                Set ^ReferralPilot("ref",id)=referral.%ToJSON()
                Do ..Audit(id,"system","pipeline.triage_claimed",{"source":(source),"previousStatus":(previousStatus)})
                Set referral=..Get(id)
            }
        }
    } Catch ex {
        Set sc=$$$ERROR($$$GeneralError,ex.DisplayString())
    }
    Lock -^ReferralPilot("claim",id)
    Return sc
}

/// Return a claimed referral to its prior state when the queue rejects it.
ClassMethod ReleaseTriageClaim(id As %String, reason As %String) As %Status
{
    Set sc=$$$OK
    Lock +^ReferralPilot("claim",id):5
    If '$Test Return $$$ERROR($$$GeneralError,"Referral is busy")
    Try {
        Set referral=..Get(id)
        If referral.%Size()=0 {
            Set sc=$$$ERROR($$$GeneralError,"Referral not found")
        } Else {
            Set previousStatus=referral.%Get("triagePreviousStatus","received")
            Do referral.%Remove("triagePreviousStatus")
            Set referral.status=previousStatus, referral.lastError=reason
            Do referral.%Remove("audit")
            Set ^ReferralPilot("ref",id)=referral.%ToJSON()
            Do ..Audit(id,"system","pipeline.triage_queue_failed",{"reason":(reason),"restoredStatus":(previousStatus)})
        }
    } Catch ex {
        Set sc=$$$ERROR($$$GeneralError,ex.DisplayString())
    }
    Lock -^ReferralPilot("claim",id)
    Return sc
}

/// Reviewer identity is mandatory in live mode unless explicitly disabled.
ClassMethod ReviewerRequired() As %Boolean
{
    Set explicit=$ZConvert($System.Util.GetEnviron("REFERRALPILOT_REQUIRE_REVIEWER"),"U")
    If explicit="TRUE" Return 1
    If explicit="FALSE" Return 0
    Set demoMode=$ZConvert($System.Util.GetEnviron("REFERRALPILOT_DEMO_MODE"),"U")="TRUE"
    Return 'demoMode
}

ClassMethod DemoResetAllowed() As %Boolean
{
    Set explicit=$ZConvert($System.Util.GetEnviron("REFERRALPILOT_ALLOW_DEMO_RESET"),"U")
    If explicit="TRUE" Return 1
    If explicit="FALSE" Return 0
    Return $ZConvert($System.Util.GetEnviron("REFERRALPILOT_DEMO_MODE"),"U")="TRUE"
}

ClassMethod ValidateReviewer(reviewer As %String) As %Status
{
    Set normalized=$ZStrip(reviewer,"<>W")
    If normalized="" Return $$$ERROR($$$GeneralError,"A reviewer identity is required")
    If ..ReviewerRequired(),($ZConvert(normalized,"L")="demo reviewer") {
        Return $$$ERROR($$$GeneralError,"A real reviewer identity is required outside demo mode")
    }
    Return $$$OK
}

ClassMethod ResetDemo() As %Status
{
    Kill ^ReferralPilot("ref"), ^ReferralPilot("message"), ^ReferralPilot("audit"), ^ReferralPilot("sequence"), ^ReferralPilot("attempt"), ^ReferralPilot("deadletter"), ^ReferralPilot("alert"), ^ReferralPilot("outbound")
    Do ..CreateFromHL7(..DemoMessage("MSG-CARDIO-001", "CARD", "Chest discomfort on exertion for three weeks. ECG attached. No shortness of breath at rest."), .one)
    Do ..CreateFromHL7(..DemoMessage("MSG-NEURO-002", "NEURO", "Progressive headaches for six weeks. Imaging report is not attached."), .two)
    Do ..CreateFromHL7(..DemoMessage("MSG-CARDIO-003", "CARD", "Acute chest pain, diaphoresis and breathlessness began today. Please assess urgently."), .three)
    Return $$$OK
}

ClassMethod DemoMessage(control As %String, code As %String, note As %String) As %String
{
    Return "MSH|^~\&|DEMO-EHR|DEMO|REFERRALPILOT|IRIS|202610250900||ORM^O01|"_control_"|P|2.5.1"_$C(13)_
        _"PID|1||SYN-"_$Piece(control,"-",3)_"^^^DEMO^MR||SAMPLE^PATIENT||19800101|U"_$C(13)_
        _"PV1|1|O"_$C(13)_"ORC|NW|"_control_$C(13)_"OBR|1|"_control_"||"_code_"^Referral request"_$C(13)_"NTE|1||"_note_$C(13)
}

ClassMethod CreateFromHL7(message As %String, Output referral As %DynamicObject) As %Status
{
    If $Length(message)>1048576 Return $$$ERROR($$$GeneralError,"HL7 message exceeds the 1 MiB limit")
    // Accept CR, LF, and CRLF segment terminators from different HL7 senders.
    Set message=$Replace(message,$C(13,10),$C(13))
    Set message=$Replace(message,$C(10),$C(13))
    If $Extract(message,1,4)'="MSH|" Return $$$ERROR($$$GeneralError,"Request body must be an HL7 v2 message beginning with MSH|")
    Set control="", patient="Synthetic patient", patientID="", specialty="GENERAL", note=""
    Set messageType="", hasPID=0, hasOBR=0, hasNTE=0
    Set i=1
    While $Piece(message,$C(13),i)'="" {
        Set segment=$Piece(message,$C(13),i), name=$Piece(segment,"|",1)
        If name="MSH" Set messageType=$Piece(segment,"|",9), control=$Piece(segment,"|",10)
        If name="PID" {
            Set hasPID=1
            Set patientID=$Piece(segment,"|",4)
            Set patient=$Piece($Piece(segment,"|",6),"^",1)_" "_$Piece($Piece(segment,"|",6),"^",2)
        }
        If name="OBR" {
            Set hasOBR=1
            Set specialty=$Piece($Piece(segment,"|",5),"^",1)
        }
        If name="NTE" {
            Set hasNTE=1
            Set note=note_$Select(note'="":" ",1:"")_$Piece(segment,"|",4)
        }
        Set i=i+1
    }
    If messageType'="ORM^O01" Return $$$ERROR($$$GeneralError,"Only ORM^O01 referral messages are accepted")
    If control="" Return $$$ERROR($$$GeneralError,"HL7 message is missing MSH-10 message control ID")
    If $Length(control)>200 Return $$$ERROR($$$GeneralError,"MSH-10 message control ID exceeds 200 characters")
    If 'hasPID Return $$$ERROR($$$GeneralError,"HL7 message is missing the PID segment")
    If patientID="" Return $$$ERROR($$$GeneralError,"HL7 message is missing PID-3 patient identifier")
    If 'hasOBR Return $$$ERROR($$$GeneralError,"HL7 message is missing the OBR segment")
    If specialty="" Return $$$ERROR($$$GeneralError,"HL7 message is missing OBR-4 requested specialty")
    If 'hasNTE Return $$$ERROR($$$GeneralError,"HL7 message is missing the NTE segment")
    If $Data(^ReferralPilot("message",control)) {
        Set referral=..Get(^ReferralPilot("message",control))
        Return $$$OK
    }
    Set id="R"_$Increment(^ReferralPilot("sequence"))
    Set referral={"id":(id),"messageControlId":(control),"patientId":(patientID),"patientLabel":($ZStrip(patient,"<>W")),"requestedSpecialty":(..NormalizeSpecialty(specialty)),"clinicalNote":(note),"originalHL7":(message),"status":"received","createdAt":($ZDateTime($Horolog,3,1)),"recommendation":{},"mode":"pending"}
    Set ^ReferralPilot("ref",id)=referral.%ToJSON(), ^ReferralPilot("message",control)=id
    Do ..Audit(id,"system","hl7.received",{"messageControlId":(control),"requestedSpecialty":(..NormalizeSpecialty(specialty))})
    Return $$$OK
}

ClassMethod NormalizeSpecialty(code As %String) As %String
{
    Set code=$ZConvert(code,"U")
    If code="CARD"!(code="CARDIO")!(code="CARDIOLOGY") Return "Cardiology"
    If code="NEURO"!(code="NEUROLOGY") Return "Neurology"
    If code="ONC"!(code="ONCOLOGY") Return "Oncology"
    If code="ORTHO"!(code="ORTHOPEDICS") Return "Orthopedics"
    Return "General Medicine"
}

ClassMethod IsApprovedSpecialty(code As %String) As %Boolean
{
    Set code=$ZConvert($ZStrip(code,"<>W"),"U")
    If code="CARD"!(code="CARDIO")!(code="CARDIOLOGY") Return 1
    If code="NEURO"!(code="NEUROLOGY") Return 1
    If code="ONC"!(code="ONCOLOGY") Return 1
    If code="ORTHO"!(code="ORTHOPEDICS") Return 1
    If code="GENERAL"!(code="GENERAL MEDICINE") Return 1
    Return 0
}

ClassMethod Get(id As %String) As %DynamicObject
{
    If '$Data(^ReferralPilot("ref",id)) Return {}
    Set result={}.%FromJSON(^ReferralPilot("ref",id))
    Set result.audit=..AuditList(id)
    Return result
}

ClassMethod List() As %DynamicArray
{
    Set result=[], id=""
    For {
        Set id=$Order(^ReferralPilot("ref",id))
        If id="" Quit
        Do result.%Push(..Get(id))
    }
    Return result
}

ClassMethod RecordRecommendation(id As %String, specialty As %String, urgency As %String, missingJSON As %String, rationale As %String, policySource As %String, mode As %String) As %Status
{
    Set referral=..Get(id)
    If referral.%Size()=0 Return $$$ERROR($$$GeneralError,"Referral not found")
    Set currentStatus=referral.status
    If (currentStatus'="received")&(currentStatus'="triage_queued")&(currentStatus'="triage_retrying")&(currentStatus'="manual_triage_required") {
        Return $$$ERROR($$$GeneralError,"Triage is closed for referral status "_currentStatus)
    }
    If '..IsApprovedSpecialty(specialty) Return $$$ERROR($$$GeneralError,"Specialty is not in the approved directory")
    Set specialty=..NormalizeSpecialty(specialty), urgency=$ZConvert(urgency,"U")
    If "ROUTINE,SOON,URGENT,EMERGENCY"'[urgency Return $$$ERROR($$$GeneralError,"Urgency must be ROUTINE, SOON, URGENT, or EMERGENCY")
    If $ZStrip(rationale,"<>W")="" Return $$$ERROR($$$GeneralError,"Recommendation rationale is required")
    Try {
        Set missing={}.%FromJSON(missingJSON)
    } Catch ex {
        Return $$$ERROR($$$GeneralError,ex.DisplayString())
    }
    If '$IsObject(missing) Set missing=[]
    Set note=$ZConvert(referral.clinicalNote,"L")
    If ((note["acute chest pain")!(note["diaphoresis")!(note["syncope")!(note["breathlessness at rest")),(urgency="ROUTINE"!(urgency="SOON")) Set urgency="URGENT"
    If (note["imaging report is not attached")!(note["imaging is missing") {
        Set found=0
        For i=0:1:missing.%Size()-1 If $ZConvert(missing.%Get(i),"L")["imaging" Set found=1
        If 'found Do missing.%Push("Attach the imaging report")
    }
    If policySource="" Set policySource="RP-COMMON-01"
    If ('$Find(policySource,"RP-CARD-01")&'$Find(policySource,"RP-NEURO-02")&'$Find(policySource,"RP-COMMON-01")&'$Find(policySource,"RP-OPS-01")&'$Find(policySource,"RP-GOV-01")) Set policySource="RP-COMMON-01"
    Set referral.recommendation={"specialty":(specialty),"urgency":(urgency),"missingInformation":(missing),"rationale":(rationale),"policySource":(policySource),"reviewRequired":1}
    Set referral.status=$Select(missing.%Size()>0:"needs_information",1:"pending_review"), referral.mode=mode
    Do referral.%Remove("triagePreviousStatus")
    Do referral.%Remove("audit")
    Set ^ReferralPilot("ref",id)=referral.%ToJSON()
    Set actor=$Select(mode="manual":"human",1:"agent")
    Do ..Audit(id,actor,"triage.recommended",{"specialty":(specialty),"urgency":(urgency),"missingInformation":(missing),"policySource":(policySource),"mode":(mode)})
    Return $$$OK
}

ClassMethod ReplayTriage(id As %String) As %Status
{
    Set referral=..Get(id)
    If referral.%Size()=0 Return $$$ERROR($$$GeneralError,"Referral not found")
    Set note=$ZConvert(referral.clinicalNote,"L"), specialty=referral.requestedSpecialty, urgency="ROUTINE", missing=[]
    If (note["acute chest pain")!(note["diaphoresis")!(note["syncope")!(note["breathlessness") Set urgency="URGENT"
    If (urgency="ROUTINE"),(note["exertion") Set urgency="SOON"
    If (note["imaging report")!(note["not attached") Do missing.%Push("Attach the imaging report")
    Set rationale="Replay decision based on the supplied synthetic referral text and the local demo triage rules. A clinician must review the recommendation."
    Set sc=..RecordRecommendation(id,specialty,urgency,missing.%ToJSON(),rationale,"ReferralPilot demo policy set","replay")
    Do ..Audit(id,"system","triage.replay",{"mode":"replay"})
    Return sc
}

ClassMethod Review(id As %String, decision As %String, reviewer As %String, comment As %String) As %Status
{
    Lock +^ReferralPilot("claim",id):5
    If '$Test Return $$$ERROR($$$GeneralError,"Referral is busy")
    Set sc=..ReviewCore(id,decision,reviewer,comment)
    Lock -^ReferralPilot("claim",id)
    Return sc
}

ClassMethod ReviewCore(id As %String, decision As %String, reviewer As %String, comment As %String) As %Status
{
    Set referral=..Get(id)
    If referral.%Size()=0 Return $$$ERROR($$$GeneralError,"Referral not found")
    If (referral.status'="pending_review")&(referral.status'="needs_information") Return $$$ERROR($$$GeneralError,"Only a pending recommendation can be reviewed")
    Set decision=$ZConvert(decision,"L")
    If (decision'="approved")&(decision'="rejected") Return $$$ERROR($$$GeneralError,"Decision must be approved or rejected")
    Set reviewer=$ZStrip(reviewer,"<>W")
    Set sc=..ValidateReviewer(reviewer)
    If $$$ISERR(sc) Return sc
    If (decision="approved"),(referral.status="needs_information"),($ZStrip(comment,"<>W")="") {
        Return $$$ERROR($$$GeneralError,"Approval with missing information requires a documented reviewer comment")
    }
    Set referral.status=decision, referral.review={"reviewer":(reviewer),"comment":(comment),"reviewedAt":($ZDateTime($Horolog,3,1))}
    Do referral.%Remove("audit")
    Set ^ReferralPilot("ref",id)=referral.%ToJSON()
    Do ..Audit(id,reviewer,"review."_decision,{"comment":(comment)})
    Return $$$OK
}

ClassMethod Audit(id As %String, actor As %String, event As %String, detail As %DynamicObject) As %Status
{
    Set n=$Increment(^ReferralPilot("audit",id))
    Set ^ReferralPilot("audit",id,n)={"at":($ZDateTime($Horolog,3,1)),"actor":(actor),"event":(event),"detail":(detail)}.%ToJSON()
    Return $$$OK
}

ClassMethod AuditList(id As %String) As %DynamicArray
{
    Set result=[], n=0
    For  Set n=$Order(^ReferralPilot("audit",id,n)) Quit:'n  Do result.%Push({}.%FromJSON(^ReferralPilot("audit",id,n)))
    Return result
}

/// True when the referral exists. Used by the API to distinguish 404 from a workflow error.
ClassMethod Exists(id As %String) As %Boolean
{
    Return $Data(^ReferralPilot("ref",id))
}

/// Number of failed automated attempts recorded for this referral.
ClassMethod Attempts(id As %String) As %Integer
{
    If '$Data(^ReferralPilot("attempt",id)) Return 0
    Return ^ReferralPilot("attempt",id)
}

ClassMethod ClearAttempts(id As %String) As %Status
{
    Kill ^ReferralPilot("attempt",id)
    Return $$$OK
}

/// Record one failed attempt and park the referral in triage_retrying.
ClassMethod RecordAttempt(id As %String, reason As %String) As %Integer
{
    Set n=$Increment(^ReferralPilot("attempt",id))
    If $Data(^ReferralPilot("ref",id)) {
        Set referral={}.%FromJSON(^ReferralPilot("ref",id))
        Set referral.status="triage_retrying", referral.lastError=reason
        Set ^ReferralPilot("ref",id)=referral.%ToJSON()
    }
    Do ..Audit(id,"system","pipeline.attempt_failed",{"attempt":(n),"reason":(reason)})
    Return n
}

/// Automated triage is exhausted: hand the referral to the manual triage queue.
ClassMethod RequestManualTriage(id As %String, reason As %String, attempts As %Integer) As %Status
{
    If '$Data(^ReferralPilot("ref",id)) Return $$$ERROR($$$GeneralError,"Referral not found")
    Set referral={}.%FromJSON(^ReferralPilot("ref",id))
    Set referral.status="manual_triage_required", referral.lastError=reason
    Set referral.fallback={"reason":(reason),"attempts":(attempts),"queuedAt":($ZDateTime($Horolog,3,1)),"queue":"manual_triage"}
    Set ^ReferralPilot("ref",id)=referral.%ToJSON()
    Do ..Audit(id,"system","pipeline.manual_fallback",{"reason":(reason),"attempts":(attempts),"queue":"manual_triage_required"})
    Return $$$OK
}

/// Human completes the triage that the automated pipeline could not finish.
ClassMethod ManualTriage(id As %String, specialty As %String, urgency As %String, missingJSON As %String, rationale As %String, reviewer As %String) As %Status
{
    Lock +^ReferralPilot("claim",id):5
    If '$Test Return $$$ERROR($$$GeneralError,"Referral is busy")
    Set sc=..ManualTriageCore(id,specialty,urgency,missingJSON,rationale,reviewer)
    Lock -^ReferralPilot("claim",id)
    Return sc
}

ClassMethod ManualTriageCore(id As %String, specialty As %String, urgency As %String, missingJSON As %String, rationale As %String, reviewer As %String) As %Status
{
    Set referral=..Get(id)
    If referral.%Size()=0 Return $$$ERROR($$$GeneralError,"Referral not found")
    If referral.status'="manual_triage_required" Return $$$ERROR($$$GeneralError,"Referral is not parked for manual triage")
    If reviewer="" Set reviewer="Demo Reviewer"
    Set reviewer=$ZStrip(reviewer,"<>W")
    Set sc=..ValidateReviewer(reviewer)
    If $$$ISERR(sc) Return sc
    Set sc=..RecordRecommendation(id,specialty,urgency,missingJSON,rationale,"RP-COMMON-01","manual")
    If $$$ISERR(sc) Return sc
    Set referral={}.%FromJSON(^ReferralPilot("ref",id))
    Set referral.manualReview={"reviewer":(reviewer),"completedAt":($ZDateTime($Horolog,3,1))}
    Set ^ReferralPilot("ref",id)=referral.%ToJSON()
    Do ..Audit(id,reviewer,"triage.manual",{"specialty":(..NormalizeSpecialty(specialty)),"urgency":($ZConvert(urgency,"U")),"note":"Human completed triage after pipeline fallback."})
    Return $$$OK
}

/// Persist one dead-letter record for a referral whose automated path failed.
ClassMethod AddDeadLetter(id As %String, reason As %String, attempts As %Integer) As %Integer
{
    Set n=$Increment(^ReferralPilot("deadletter",id))
    Set ^ReferralPilot("deadletter",id,n)={"id":(id),"reason":(reason),"attempts":(attempts),"at":($ZDateTime($Horolog,3,1))}.%ToJSON()
    Do ..Audit(id,"system","pipeline.dead_letter",{"reason":(reason),"attempts":(attempts),"sequence":(n)})
    Return n
}

ClassMethod DeadLetters() As %DynamicArray
{
    Set result=[], id=""
    For {
        Set id=$Order(^ReferralPilot("deadletter",id))
        If id="" Quit
        Set n=0
        For {
            Set n=$Order(^ReferralPilot("deadletter",id,n))
            If 'n Quit
            Do result.%Push({}.%FromJSON(^ReferralPilot("deadletter",id,n)))
        }
    }
    Return result
}

ClassMethod AddAlert(source As %String, text As %String) As %Status
{
    Set n=$Increment(^ReferralPilot("alert"))
    Set ^ReferralPilot("alert",n)={"at":($ZDateTime($Horolog,3,1)),"source":(source),"text":(text)}.%ToJSON()
    Return $$$OK
}

ClassMethod Alerts() As %DynamicArray
{
    Set result=[], n=0
    For {
        Set n=$Order(^ReferralPilot("alert",n))
        If 'n Quit
        Do result.%Push({}.%FromJSON(^ReferralPilot("alert",n)))
    }
    Return result
}

/// Return the persisted downstream HL7 message for an approved referral.
ClassMethod Outbound(id As %String) As %DynamicObject
{
    If '$Data(^ReferralPilot("outbound",id)) Return {}
    Return {"id":(id),"message":(^ReferralPilot("outbound",id))}
}

/// One call that answers "is the pipeline healthy?" for the API and the dashboard.
ClassMethod PipelineStats() As %DynamicObject
{
    Set counts={}, total=0, id=""
    For {
        Set id=$Order(^ReferralPilot("ref",id))
        If id="" Quit
        Set referral={}.%FromJSON(^ReferralPilot("ref",id)), st=referral.status
        If st="" Set st="received"
        Do counts.%Set(st,counts.%Get(st,0)+1)
        Set total=total+1
    }
    Set attempts=0, aid=""
    For {
        Set aid=$Order(^ReferralPilot("attempt",aid))
        If aid="" Quit
        Set attempts=attempts+^ReferralPilot("attempt",aid)
    }
    Set deadLetters=0, did=""
    For {
        Set did=$Order(^ReferralPilot("deadletter",did))
        If did="" Quit
        Set n=0
        For {
            Set n=$Order(^ReferralPilot("deadletter",did,n))
            If 'n Quit
            Set deadLetters=deadLetters+1
        }
    }
    Set alerts=0, an=0
    For {
        Set an=$Order(^ReferralPilot("alert",an))
        If 'an Quit
        Set alerts=alerts+1
    }
    Set manualQueue=counts.%Get("manual_triage_required",0), retrying=counts.%Get("triage_retrying",0)
    Return {"total":(total),"byStatus":(counts),"manualQueue":(manualQueue),"retrying":(retrying),"deadLetters":(deadLetters),"alerts":(alerts),"attemptsRecorded":(attempts)}
}

}
