<?xml version='1.0' encoding='UTF-8'?>
<Project Type="Project" LVVersion="21008000">
	<Property Name="NI.LV.All.SaveVersion" Type="Str">21.0</Property>
	<Property Name="NI.LV.All.SourceOnly" Type="Bool">true</Property>
	<Property Name="NI.Project.Description" Type="Str"></Property>
	<Item Name="My Computer" Type="My Computer">
		<Property Name="server.app.propertiesEnabled" Type="Bool">true</Property>
		<Property Name="server.control.propertiesEnabled" Type="Bool">true</Property>
		<Property Name="server.tcp.enabled" Type="Bool">false</Property>
		<Property Name="server.tcp.port" Type="Int">0</Property>
		<Property Name="server.tcp.serviceName" Type="Str">My Computer/VI Server</Property>
		<Property Name="server.tcp.serviceName.default" Type="Str">My Computer/VI Server</Property>
		<Property Name="server.vi.callsEnabled" Type="Bool">true</Property>
		<Property Name="server.vi.propertiesEnabled" Type="Bool">true</Property>
		<Property Name="specify.custom.address" Type="Bool">false</Property>
		<Item Name="VI Package install actions" Type="Folder">
			<Property Name="NI.SortType" Type="Int">3</Property>
			<Item Name="VIP_Post-Uninstall Custom Action.vi" Type="VI" URL="../deployment/VIP_Post-Uninstall Custom Action.vi"/>
			<Item Name="VIP_Pre-Install Custom Action.vi" Type="VI" URL="../deployment/VIP_Pre-Install Custom Action.vi"/>
			<Item Name="VIP_Pre-Uninstall Custom Action.vi" Type="VI" URL="../deployment/VIP_Pre-Uninstall Custom Action.vi"/>
			<Item Name="VIP_Post-Install Custom Action.vi" Type="VI" URL="../deployment/VIP_Post-Install Custom Action.vi"/>
		</Item>
		<Item Name="ApplyVIPC.vi" Type="VI" URL="../deployment/ApplyVIPC.vi"/>
		<Item Name="BuildVIPackage.vi" Type="VI" URL="../deployment/BuildVIPackage.vi"/>
		<Item Name="Modify_VIPB_Display_Information.vi" Type="VI" URL="../deployment/Modify_VIPB_Display_Information.vi"/>
		<Item Name="VIPM API_vipm_api.lvlib" Type="Library" URL="/&lt;vilib&gt;/JKI/VIPM API/VIPM API_vipm_api.lvlib"/>
		<Item Name="Dependencies" Type="Dependencies"/>
		<Item Name="Build Specifications" Type="Build"/>
	</Item>
</Project>
