enum ShipDomainType {
  shipBodyDomain('shipBodyDomain'),
  exclusiveDomain('exclusiveDomain'),
  cautionDomain('cautionDomain'),
  ;

  const ShipDomainType(this.value);
  final String value;
}
