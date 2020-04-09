ruleset shop_profile {
  meta {
    use module io.picolabs.wrangler alias wrangler
    shares __testing
  }
  global {
    __testing = { "queries":
      [ { "name": "__testing" }
      //, { "name": "entry", "args": [ "key" ] }
      ] , "events":
      [ //{ "domain": "d1", "type": "t1" }
      //, { "domain": "d2", "type": "t2", "attrs": [ "a1", "a2" ] }
      ]
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
  
  
  rule ruleset_added { 
    //initialize all entity variables here
    select when wrangler ruleset_added where rids >< meta:rid
    always {
        ent:name := wrangler:myself(){"name"}
        ent:location := "UNKNOWN"
        ent:phone_number := "+19999999999"
        ent:min_driver_rating := 0
        ent:auto_select := false
    }
  }
}
