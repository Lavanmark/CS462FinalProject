ruleset shop_profile {
  meta {
    use module io.picolabs.wrangler alias wrangler
    use module io.picolabs.subscription alias subscription
    shares __testing, get_message_profile, get_auto_select
    provides get_message_profile, get_auto_select
  }
  global {
    __testing = { "queries":
      [ { "name": "__testing" }
      , { "name": "get_auto_select"}
      ] , "events":
      [ { "domain": "shop", "type": "toggle_auto_accept" }
      //, { "domain": "d2", "type": "t2", "attrs": [ "a1", "a2" ] }
      ]
    }
    
    get_message_profile = function() {
      {
        "location": ent:location,
        "min_driver_rating": ent:min_driver_rating,
        "contact_tx": wrangler:myself(){"eci"}
      }
    }
    
    get_auto_select = function() {
      ent:auto_select
    }
    
  }
  
  rule update_profile {
    select when shop update_profile
    pre {
      name = event:attr("name")
      loc = event:attr("location")
      number = event:attr("phone_number")
    }
    send_directive("shop", {"update_profile": "Profile Updated!"})
    always {
      ent:name := name
      ent:location := loc
      ent:phone_number := number
    }
  }
  
  rule toggle_auto_select {
    select when shop toggle_auto_select
    always{
      ent:auto_select := not ent:auto_select
    }
  }
  
  rule ruleset_added { 
    //initialize all entity variables here
    select when wrangler ruleset_added where rids >< meta:rid
    always {
        ent:name := wrangler:myself(){"name"}
        ent:location := "UNKNOWN"
        ent:phone_number := "+19999999999"
        ent:min_driver_rating := 0
        ent:auto_select := true
    }
  }
}
