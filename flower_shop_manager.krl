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
      [ //{ "domain": "d1", "type": "t1" }
        { "domain": "flower_delivery", "type": "new_shop", "attrs": [ "Shop Name" ] }
      ]
    }
    
    
    get_drivers = function(){ //gets a list of drivers from the driver manager to use for a new shop.
      subs = subscriptions:established().klog("all subs:")
      driver_manager = subs.filter(function(info){
        info{"Tx_role"} == "driver_manager"
      }).klog("selected subs").head()
      wrangler:skyQuery(driver_manager{"Tx"}, "driver_manager", "get_drivers", {"num_drivers" : 3})
    }
    
    shop_rulesets = []
    default_location = "LOCATION_UNKNOWN"
    default_number = "+19999999999"
  }
  
  
  rule new_shop {
    select when flower_delivery new_shop
    pre{
      shop_name = event:attr("Shop Name").klog("New shop name:")
      exists = ent:all_shops >< shop_name
    }
    if exists then 
      send_directive("flower_delivery", {"new_shop": "Shop by the name of '" + shop_name + "' already exist!"})
    notfired {
      raise wrangler event "child_creation"
      attributes {"name": shop_name,
                  "color": "#ffff00",
                  "rids": shop_rulesets }
    }
  }
  
  rule fresh_drivers {
    select when wrangler new_child_created
    pre {
      shop_name = event:attr("name")
      eci = event:attr("eci")
      drivers = get_drivers()
    }
    
  }
  
  rule update_child_profile {
   select when wrangler new_child_created
     pre {
       shop_name = event:attr("name")
       eci = event:attr("eci")
     }
     event:send({"eci":eci, 
                 "domain":"shop", 
                 "type":"profile_updated", 
                 "attrs":{"name": shop_name, 
                          "location": default_location, 
                          "phone_number": default_number}})
  }
  
  
  
  

  rule ruleset_added { 
    //initialize all entity variables here
    select when wrangler ruleset_added where rids >< meta:rid
    always {
        ent:all_shops := {}
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