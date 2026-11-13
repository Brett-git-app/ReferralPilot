Class ReferralPilot.Production Extends Ens.Production
{

XData ProductionDefinition
{
<Production Name="ReferralPilot.Production" TestingEnabled="true" LogGeneralTraceEvents="true">
  <Description>HL7 referral intake, AI-assisted triage, human review, and downstream routing</Description>
  <ActorPoolSize>2</ActorPoolSize>
  <Item Name="HL7Service" Category="Service" ClassName="ReferralPilot.HL7Service" PoolSize="1" Enabled="true" Foreground="false" Comment="Inbound HL7 v2 service: validates referral files and queues AI triage" LogTraceEvents="true" Schedule="">
    <Setting Target="Adapter" Name="CallInterval">5</Setting>
  </Item>
  <Item Name="TriageProcess" Category="Process" ClassName="ReferralPilot.TriageProcess" PoolSize="2" Enabled="true" Foreground="false" Comment="Runs policy-grounded AI recommendations; never approves referrals" LogTraceEvents="true" Schedule="" />
  <Item Name="FallbackOperation" Category="Operation" ClassName="ReferralPilot.FallbackOperation" PoolSize="1" Enabled="true" Foreground="false" Comment="Dead-letter, alert, and manual triage queue for exhausted automated attempts" LogTraceEvents="true" Schedule="">
    <Setting Target="Host" Name="DeadLetterDir">/tmp/referralpilot-deadletter</Setting>
  </Item>
  <Item Name="RoutingOperation" Category="Operation" ClassName="ReferralPilot.RoutingOperation" PoolSize="1" Enabled="true" Foreground="false" Comment="Emits an HL7 ORM^O01 acceptance for approved referrals only" LogTraceEvents="true" Schedule="" />
</Production>
}

}
