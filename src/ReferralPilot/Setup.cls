Include %occStatus

Class ReferralPilot.Setup Extends %RegisteredObject
{

/// Configure the production to start automatically in this namespace, then start it now.
ClassMethod StartProduction() As %Status
{
    Set ^Ens.AutoStart="ReferralPilot.Production"
    Return ##class(Ens.Director).StartProduction("ReferralPilot.Production")
}

}
