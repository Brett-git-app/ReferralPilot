Class ReferralPilot.FallbackRequest Extends Ens.Request
{

Property ReferralID As %String(MAXLEN = 64);

/// Diagnostic message from the last failed automated attempt.
Property Reason As %String(MAXLEN = 1000);

/// Number of automated attempts before the pipeline gave up.
Property Attempts As %Integer;

/// Component that raised the fallback.
Property Source As %String(MAXLEN = 128);

}
