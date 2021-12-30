data "aws_region" "this" {}
data "aws_caller_identity" "this" {}

locals {
  vpc_attachments_without_default_route_table_association = {
    for k, v in var.vpc_attachments : k => v if lookup(v, "transit_gateway_default_route_table_association", true) != true
  }

  vpc_attachments_without_default_route_table_propagation = {
    for k, v in var.vpc_attachments : k => v if lookup(v, "transit_gateway_default_route_table_propagation", true) != true
  }

  # List of maps with key and route values
  vpc_attachments_with_routes = chunklist(flatten([
    for k, v in var.vpc_attachments : setproduct([{ key = k }], v["tgw_routes"]) if length(lookup(v, "tgw_routes", {})) > 0
  ]), 2)

  tgw_peering_attachments_with_routes = chunklist(flatten([
    for k, v in var.tgw_peering_attachments : setproduct([{ key = k }], v["tgw_routes"]) if length(lookup(v, "tgw_routes", {})) > 0
  ]), 2)

  tgw_peering_attachment_requesters = {
    for k, v in var.tgw_peering_attachments : k => v if lookup(v, "type", {}) == "requester"
  }

  tgw_peering_attachment_accepters = {
    for k, v in var.tgw_peering_attachments : k => v if lookup(v, "type", {}) == "accepter"
  }

  tgw_default_route_table_tags_merged = merge(
    {
      "Name" = format("%s", var.name)
    },
    var.tags,
    var.tgw_default_route_table_tags,
  )

  vpc_route_table_destination_cidr = flatten([
    for k, v in var.vpc_attachments : [
      for rtb_id in lookup(v, "vpc_route_table_ids", []) : [
        for tgw_destination_cidr in v["tgw_destination_cidrs"] : {
          rtb_id = rtb_id
          cidr = tgw_destination_cidr
        }
      ]
    ]
  ])
}

resource "aws_ec2_transit_gateway" "this" {
  count = var.create_tgw ? 1 : 0

  description                     = coalesce(var.description, var.name)
  amazon_side_asn                 = var.amazon_side_asn
  default_route_table_association = var.enable_default_route_table_association ? "enable" : "disable"
  default_route_table_propagation = var.enable_default_route_table_propagation ? "enable" : "disable"
  auto_accept_shared_attachments  = var.enable_auto_accept_shared_attachments ? "enable" : "disable"
  vpn_ecmp_support                = var.enable_vpn_ecmp_support ? "enable" : "disable"
  dns_support                     = var.enable_dns_support ? "enable" : "disable"

  tags = merge(
    {
      "Name" = format("%s", var.name)
    },
    var.tags,
    var.tgw_tags,
  )
}

resource "aws_ec2_tag" "this" {
  for_each    = var.create_tgw && var.enable_default_route_table_association ? local.tgw_default_route_table_tags_merged : {}
  resource_id = aws_ec2_transit_gateway.this[0].association_default_route_table_id
  key         = each.key
  value       = each.value
}

#########################
# Route table and routes
#########################
resource "aws_ec2_transit_gateway_route_table" "this" {
  count = (var.create_tgw && !var.enable_default_route_table_association) || (var.create_tgw && !var.enable_default_route_table_propagation) ? 1 : 0

  transit_gateway_id = aws_ec2_transit_gateway.this[0].id

  tags = merge(
    {
      "Name" = format("%s", var.name)
    },
    var.tags,
    var.tgw_route_table_tags,
  )
}

# VPC attachment routes
resource "aws_ec2_transit_gateway_route" "this" {
  count = length(local.vpc_attachments_with_routes)

  destination_cidr_block = local.vpc_attachments_with_routes[count.index][1]["destination_cidr_block"]
  blackhole              = lookup(local.vpc_attachments_with_routes[count.index][1], "blackhole", null)

  transit_gateway_route_table_id = var.create_tgw ? (var.enable_default_route_table_association ? aws_ec2_transit_gateway.this[0].association_default_route_table_id : aws_ec2_transit_gateway_route_table.this[0].id) : var.transit_gateway_route_table_id
  transit_gateway_attachment_id  = tobool(lookup(local.vpc_attachments_with_routes[count.index][1], "blackhole", false)) == false ? aws_ec2_transit_gateway_vpc_attachment.this[local.vpc_attachments_with_routes[count.index][0]["key"]].id : null
}

resource "aws_route" "this" {
  for_each = { for x in local.vpc_route_table_destination_cidr : "${x.rtb_id}-${x.cidr}" => [x.rtb_id, x.cidr] }

  route_table_id         = each.value[0]
  destination_cidr_block = each.value[1]
  transit_gateway_id     = var.create_tgw ? aws_ec2_transit_gateway.this[0].id : var.transit_gateway_id
}

###########################################################
# VPC Attachments, route table association and propagation
###########################################################
resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  for_each = var.vpc_attachments

  transit_gateway_id = lookup(each.value, "tgw_id", var.create_tgw ? aws_ec2_transit_gateway.this[0].id : var.transit_gateway_id)
  vpc_id             = each.value["vpc_id"]
  subnet_ids         = each.value["subnet_ids"]

  dns_support                                     = lookup(each.value, "dns_support", true) ? "enable" : "disable"
  ipv6_support                                    = lookup(each.value, "ipv6_support", false) ? "enable" : "disable"
  appliance_mode_support                          = lookup(each.value, "appliance_mode_support", false) ? "enable" : "disable"
  transit_gateway_default_route_table_association = lookup(each.value, "transit_gateway_default_route_table_association", true)
  transit_gateway_default_route_table_propagation = lookup(each.value, "transit_gateway_default_route_table_propagation", true)

  tags = merge(
    {
      Name = format("%s-%s", var.name, each.key)
    },
    var.tags,
    var.tgw_vpc_attachment_tags,
  )
}

resource "aws_ec2_transit_gateway_route_table_association" "this" {
  for_each = local.vpc_attachments_without_default_route_table_association

  # Create association if it was not set already by aws_ec2_transit_gateway_vpc_attachment resource
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[each.key].id
  transit_gateway_route_table_id = coalesce(lookup(each.value, "transit_gateway_route_table_id", null), var.transit_gateway_route_table_id, aws_ec2_transit_gateway_route_table.this[0].id)
}

resource "aws_ec2_transit_gateway_route_table_propagation" "this" {
  for_each = local.vpc_attachments_without_default_route_table_propagation

  # Create association if it was not set already by aws_ec2_transit_gateway_vpc_attachment resource
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[each.key].id
  transit_gateway_route_table_id = coalesce(lookup(each.value, "transit_gateway_route_table_id", null), var.transit_gateway_route_table_id, aws_ec2_transit_gateway_route_table.this[0].id)
}

##########################
# Resource Access Manager
##########################
resource "aws_ram_resource_share" "this" {
  count = var.create_tgw && var.share_tgw ? 1 : 0

  name                      = coalesce(var.ram_name, var.name)
  allow_external_principals = var.ram_allow_external_principals

  tags = merge(
    {
      "Name" = format("%s", coalesce(var.ram_name, var.name))
    },
    var.tags,
    var.ram_tags,
  )
}

resource "aws_ram_resource_association" "this" {
  count = var.create_tgw && var.share_tgw ? 1 : 0

  resource_arn       = aws_ec2_transit_gateway.this[0].arn
  resource_share_arn = aws_ram_resource_share.this[0].id
}

resource "aws_ram_principal_association" "this" {
  count = var.create_tgw && var.share_tgw ? length(var.ram_principals) : 0

  principal          = var.ram_principals[count.index]
  resource_share_arn = aws_ram_resource_share.this[0].arn
}

resource "aws_ram_resource_share_accepter" "this" {
  count = ! var.create_tgw && var.share_tgw ? 1 : 0

  share_arn = var.ram_resource_share_arn
}

###########################################################
# Transit Gateway Peering Attachments and Routes
###########################################################
resource "aws_ec2_transit_gateway_peering_attachment" "this" {
  for_each = local.tgw_peering_attachment_requesters

  transit_gateway_id = lookup(each.value, "tgw_id", var.create_tgw ? aws_ec2_transit_gateway.this[0].id : var.transit_gateway_id)

  peer_account_id = lookup(each.value, "peer_account_id", data.aws_caller_identity.this.account_id)
  peer_region = lookup(each.value, "peer_region", data.aws_region.this.name)
  peer_transit_gateway_id = lookup(each.value, "peer_transit_gateway_id", null)

  tags = merge(
    {
      Name = format("%s-%s", var.name, each.key)
    },
    var.tags,
    var.tgw_vpc_attachment_tags,
  )
}

resource "aws_ec2_transit_gateway_peering_attachment_accepter" "this" {
  for_each = local.tgw_peering_attachment_accepters

  transit_gateway_attachment_id = lookup(each.value, "transit_gateway_attachment_id", null)

  tags = merge(
    {
      Name = format("%s-%s", var.name, each.key)
    },
    var.tags,
    var.tgw_vpc_attachment_tags,
  )
}

resource "aws_ec2_transit_gateway_route" "tgw_peer" {
  count = length(local.tgw_peering_attachments_with_routes)

  destination_cidr_block = local.tgw_peering_attachments_with_routes[count.index][1]["destination_cidr_block"]
  blackhole              = lookup(local.tgw_peering_attachments_with_routes[count.index][1], "blackhole", null)

  transit_gateway_route_table_id = var.create_tgw ? (var.enable_default_route_table_association ? aws_ec2_transit_gateway.this[0].association_default_route_table_id : aws_ec2_transit_gateway_route_table.this[0].id) : var.transit_gateway_route_table_id
  transit_gateway_attachment_id = tobool(lookup(local.tgw_peering_attachments_with_routes[count.index][1], "blackhole", false)) == false ? (
    lookup(var.tgw_peering_attachments[local.tgw_peering_attachments_with_routes[count.index][0]["key"]], "type", null) == "requester" ?
      aws_ec2_transit_gateway_peering_attachment.this[local.tgw_peering_attachments_with_routes[count.index][0]["key"]].id :
      aws_ec2_transit_gateway_peering_attachment_accepter.this[local.tgw_peering_attachments_with_routes[count.index][0]["key"]].id
  ) : null
}
