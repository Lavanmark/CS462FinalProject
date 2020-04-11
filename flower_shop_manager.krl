ruleset flower_shop_manager {
  meta {
    use module io.picolabs.wrangler alias wrangler
    use module io.picolabs.subscription alias subscriptions
    shares __testing, get_drivers
  }
  global {
    __testing = { "queries":
      [ { "name": "__testing" },
        { "name": "get_drivers"}
      ] , "events":
      [ { "domain": "flower_delivery", "type": "new_shop", "attrs": [ "Shop Name", "Shop Location", "Shop Phone Number" ] },
        { "domain": "flower_delivery", "type": "remove_shop", "attrs": [ "Shop Name" ] }
      ]
    }
    
    
    get_drivers = function() { //gets a list of drivers from the driver manager to use for a new shop.
      subs = subscriptions:established().klog("all subs:")
      driver_manager = subs.filter(function(info){
        info{"Tx_role"} == "driver_manager"
      }).klog("selected subs").head()
      wrangler:skyQuery(driver_manager{"Tx"}, "driver_manager", "get_drivers", {"num_drivers": initial_drivers})
    }
    
    shop_exists = function(shop_name) {
      shops = wrangler:children(shop_name)
      shops.isnull() == false && shops.length() > 0
    }
    
    shop_rulesets = ["shop", "shop_profile", "shop_keys", "customer_communication", "google_maps_keys", "distance"]
    initial_drivers = 2
  }
  
  
  rule new_shop {
    select when flower_delivery new_shop
    pre {
      shop_name = event:attr("Shop Name").klog("New shop name:")
      shop_location = event:attr("Shop Location")
      shop_phone = event:attr("Shop Phone Number")
    }
    if shop_name.isnull() || shop_name == "" || shop_exists(shop_name) then 
      send_directive("flower_delivery", {"new_shop": "Shop by the name of '" 
                                  + shop_name 
                                  + "' already exists or cannot be created!"})
    notfired {
      ent:pre_init_shops{shop_name} := {"location": shop_location,
                                   "phone_number": shop_phone}
      raise wrangler event "child_creation"
      attributes {"name": shop_name,
                  "color": "#00ff00",
                  "rids": shop_rulesets }
    }
  }
  
  rule set_new_child_drivers {
    select when wrangler child_initialized
    pre {
      shop_name = event:attr("name")
      eci = event:attr("eci")
    }
    always {
      raise flower_delivery event "need_drivers"
        attributes {"name": shop_name,
                    "eci": eci}
    }
  }
  
  rule child_needs_drivers {
    select when flower_delivery need_drivers
    pre {
      shop_name = event:attr("name")
      eci = event:attr("eci")
      drivers = get_drivers()
    }
    if drivers.isnull() == false then
      event:send({"eci":eci, 
                  "domain":"shop", 
                  "type":"initial_drivers", 
                  "attrs":{ "num_drivers": drivers.length(), 
                            "drivers": drivers}})
  }
  
  rule update_child_profile {
    select when wrangler child_initialized
    pre {
      shop_name = event:attr("name")
      eci = event:attr("eci")
    }
    if ent:pre_init_shops >< shop_name then
      event:send({"eci":eci, 
                  "domain":"shop", 
                  "type":"profile_updated", 
                  "attrs":{ "name": shop_name,
                            "location": ent:pre_init_shops{shop_name}{"location"},
                            "phone_number": ent:pre_init_shops{shop_name}{"phone_number"}}})
    fired {
      ent:pre_init_shops := ent:pre_init_shops.delete(shop_name)
    }
  }
  
  rule remove_flower_shop {
    select when flower_delivery remove_shop
    pre {
      shop_name = event:attr("Shop Name")
    }
    if shop_exists(shop_name) == false then 
      send_directive("flower_delivery", {"destroy" : "The shop does not exist! Could not remove."})
    notfired {
      raise wrangler event "child_deletion"
        attributes {"name": shop_name};
    }
  }

  rule ruleset_added { 
    //initialize all entity variables here
    select when wrangler ruleset_added where rids >< meta:rid
    always {
        ent:pre_init_shops := {}
    }
  }
  
  rule auto_accept {
    select when wrangler inbound_pending_subscription_added
    always {
      raise wrangler event "pending_subscription_approval" 
        attributes event:attrs;
    }
  }
}
