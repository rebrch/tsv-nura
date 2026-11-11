from pathlib import Path
s=Path("apq8053-lenovo-cd-18781y.dts").read_text()
def rep(a,b,cnt=1):
    global s
    assert s.count(a)==cnt,(a,s.count(a)); s=s.replace(a,b)
rep("""					l2 {
						regulator-min-microvolt = <0xee098>;
						regulator-max-microvolt = <0x12b128>;
						regulator-always-on;
""","""					l2 {
						regulator-min-microvolt = <0x124f80>;
						regulator-max-microvolt = <0x12b128>;
						regulator-always-on;
						phandle = <0xd6>;
""")
rep("""					l17 {
						regulator-min-microvolt = <0x2b7cd0>;
						regulator-max-microvolt = <0x2b7cd0>;
""","""					l17 {
						regulator-min-microvolt = <0x2b7cd0>;
						regulator-max-microvolt = <0x2b7cd0>;
						phandle = <0xd7>;
""")
i=s.index("camss-mclk0-default-state {"); j=s.index("};",i)
s=s[:j]+"\tphandle = <0xd0>;\n\t\t\t"+s[j:]
i=s.index("\tsoc@0 {")
s=s[:i]+"""	cam-vana-regulator {
		compatible = "regulator-fixed";
		regulator-name = "cam_vana";
		regulator-min-microvolt = <0x2b7cd0>;
		regulator-max-microvolt = <0x2b7cd0>;
		gpio = <0x38 0x77 0x00>;
		enable-active-high;
		vin-supply = <0xd7>;
		startup-delay-us = <0x3e8>;
		phandle = <0xd4>;
	};

	cam-vdig-regulator {
		compatible = "regulator-fixed";
		regulator-name = "cam_vdig";
		regulator-min-microvolt = <0x124f80>;
		regulator-max-microvolt = <0x124f80>;
		gpio = <0x38 0x76 0x00>;
		enable-active-high;
		vin-supply = <0xd6>;
		startup-delay-us = <0x3e8>;
		phandle = <0xd5>;
	};

"""+s[i:]
i=s.index("cci@1b0c000 {"); j=s.index("i2c-bus@1",i)
blk=s[i:j]
blk=blk.replace('pinctrl-0 = <0x55 0x56>;','pinctrl-0 = <0x55 0x56 0xd0>;').replace('status = "disabled";','status = "okay";')
old="""			i2c-bus@0 {
				reg = <0x00>;
				clock-frequency = <0x61a80>;
				#address-cells = <0x01>;
				#size-cells = <0x00>;
"""
assert blk.count(old)==1
blk=blk.replace(old, old+"""
				camera@37 {
					compatible = "samsung,s5kc505a";
					reg = <0x37>;
					clocks = <0x24 0x6b>;
					assigned-clocks = <0x24 0xbb>;
					assigned-clock-rates = <0x16e3600>;
					reset-gpios = <0x38 0x28 0x01>;
					standby-gpios = <0x38 0x27 0x01>;
					dovdd-supply = <0x45>;
					avdd-supply = <0xd4>;
					dvdd-supply = <0xd5>;
					rotation = <0x10e>;
					orientation = <0x00>;

					port {
						endpoint {
							data-lanes = <0x01 0x02>;
							link-frequencies = /bits/ 64 <0x7b05740 0x1991f240 0x1c9c3800>;
							remote-endpoint = <0xd3>;
							phandle = <0xd2>;
						};
					};
				};
""")
s=s[:i]+blk+s[j:]
i=s.index("camss@1b00020 {"); j=s.index("\n\t\t};",i)
blk=s[i:j]
blk=blk.replace('status = "disabled";','status = "okay";\n\t\t\tvdda-supply = <0x30>;')
old="""			ports {
				#address-cells = <0x01>;
				#size-cells = <0x00>;
			};"""
assert blk.count(old)==1
blk=blk.replace(old,"""			ports {
				#address-cells = <0x01>;
				#size-cells = <0x00>;

				port@0 {
					reg = <0x00>;

					endpoint {
						clock-lanes = <0x07>;
						data-lanes = <0x00 0x01>;
						remote-endpoint = <0xd2>;
						phandle = <0xd3>;
					};
				};
			};""")
s=s[:i]+blk+s[j:]
Path("tsv-camera.dts").write_text(s)
