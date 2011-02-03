val create :
	__context:Context.t -> name_label:string -> name_description:string -> [ `VM_appliance ] Ref.t
val destroy :
	__context:Context.t -> self:[ `VM_appliance ] Ref.t -> unit
val start :
	__context:Context.t -> self:[ `VM_appliance ] Ref.t -> unit
val clean_shutdown :
	__context:Context.t -> self:[ `VM_appliance ] Ref.t -> unit
val hard_shutdown :
	__context:Context.t -> self:[ `VM_appliance ] Ref.t -> unit
