Include %occStatus

/// Durable demo workflow state. Original HL7 payloads and audit events are kept in IRIS globals.
Class ReferralPilot.Store Extends %RegisteredObject
{

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
    // Accept CR, LF, and CRLF segment terminators from different HL7 senders.
    Set message=$Replace(message,$C(13,10),$C(13))
    Set message=$Replace(message,$C(10),$C(13))
    If $Extract(message,1,4)'="MSH|" Return $$$ERROR($$$GeneralError,"Request body must be an HL7 v2 message beginning with MSH|")
    Set control="", patient="Synthetic patient", patientID="", specialty="GENERAL", note=""
    Set i=1
    While $Piece(message,$C(13),i)'="" {
        Set segment=$Piece(message,$C(13),i), name=$Piece(segment,"|",1)
        If name="MSH" Set control=$Piece(segment,"|",10)
        If name="PID" {
            Set patientID=$Piece(segment,"|",4)
            Set patient=$Piece($Piece(segment,"|",6),"^",1)_" "_$Piece($Piece(segment,"|",6),"^",2)
        }
        If name="OBR" Set specialty=$Piece($Piece(segment,"|",5),"^",1)
        If name="NTE" Set note=note_$Select(note'="":" ",1:"")_$Piece(segment,"|",4)
        Set i=i+1
    }
    If control="" Return $$$ERROR($$$GeneralError,"HL7 message is missing MSH-10 message control ID")
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
    Set specialty=..NormalizeSpecialty(specialty), urgency=$ZConvert(urgency,"U")
    If "Cardiology,Neurology,Oncology,Orthopedics,General Medicine"'[specialty Return $$$ERROR($$$GeneralError,"Specialty is not in the approved directory")
    If "ROUTINE,SOON,URGENT,EMERGENCY"'[urgency Return $$$ERROR($$$GeneralError,"Urgency must be ROUTINE, SOON, URGENT, or EMERGENCY")
    Set missing={}.%FromJSON(missingJSON)
    If '$IsObject(missing) Set missing=[]
    Set note=$ZConvert(referral.clinicalNote,"L")
    If ((note["acute chest pain")!(note["diaphoresis")!(note["syncope")!(note["breathlessness at rest")),(urgency="ROUTINE"!(urgency="SOON")) Set urgency="URGENT"
    If (note["imaging report is not attached")!(note["imaging is missing") {
        Set found=0
        For i=0:1:missing.%Size()-1 If $ZConvert(missing.%Get(i),"L")["imaging" Set found=1
        If 'found Do missing.%Push("Attach the imaging report")
    }
    If (policySource'=""),('$Find(policySource,"RP-CARD-01")&'$Find(policySource,"RP-NEURO-02")&'$Find(policySource,"RP-COMMON-01")&'$Find(policySource,"RP-OPS-01")&'$Find(policySource,"RP-GOV-01")) Set policySource="RP-COMMON-01"
    Set referral.recommendation={"specialty":(specialty),"urgency":(urgency),"missingInformation":(missing),"rationale":(rationale),"policySource":(policySource),"reviewRequired":1}
    Set referral.status=$Select(missing.%Size()>0:"needs_information",1:"pending_review"), referral.mode=mode
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
    Set referral=..Get(id)
    If referral.%Size()=0 Return $$$ERROR($$$GeneralError,"Referral not found")
    If (referral.status'="pending_review")&(referral.status'="needs_information") Return $$$ERROR($$$GeneralError,"Only a pending recommendation can be reviewed")
    If (decision'="approved")&(decision'="rejected") Return $$$ERROR($$$GeneralError,"Decision must be approved or rejected")
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
    If '$Data(^ReferralPilot("ref",id)) Return $$$ERROR($$$GeneralError,"Referral not found")
    If reviewer="" Set reviewer="Demo Reviewer"
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
