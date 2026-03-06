//dual_port_bram
`timescale 1ns/1ps

module dual_port_bram(
	clka,
	dina,
	addra,
	wea,
	douta,
	clkb,
	dinb,
	addrb,
	web,
	doutb);


input clka;
input [63 : 0] dina;
input [7 : 0] addra;
input [0 : 0] wea;
output [63 : 0] douta;
input clkb;
input [63 : 0] dinb;
input [7 : 0] addrb;
input [0 : 0] web;
output [63 : 0] doutb;

// synthesis translate_off
      BLK_MEM_GEN_V2_7 #(
		.C_ADDRA_WIDTH(8),
		.C_ADDRB_WIDTH(8),
		.C_ALGORITHM(1),
		.C_BYTE_SIZE(9),
		.C_COMMON_CLK(0),
		.C_DEFAULT_DATA("0"),
		.C_DISABLE_WARN_BHV_COLL(0),
		.C_DISABLE_WARN_BHV_RANGE(0),
		.C_FAMILY("virtex2p"),
		.C_HAS_ENA(0),
		.C_HAS_ENB(0),
		.C_HAS_MEM_OUTPUT_REGS_A(0),
		.C_HAS_MEM_OUTPUT_REGS_B(0),
		.C_HAS_MUX_OUTPUT_REGS_A(1),
		.C_HAS_MUX_OUTPUT_REGS_B(1),
		.C_HAS_REGCEA(0),
		.C_HAS_REGCEB(0),
		.C_HAS_SSRA(0),
		.C_HAS_SSRB(0),
		.C_INIT_FILE_NAME("no_coe_file_loaded"),
		.C_LOAD_INIT_FILE(0),
		.C_MEM_TYPE(2),
		.C_MUX_PIPELINE_STAGES(0),
		.C_PRIM_TYPE(1),
		.C_READ_DEPTH_A(256),
		.C_READ_DEPTH_B(256),
		.C_READ_WIDTH_A(64),
		.C_READ_WIDTH_B(64),
		.C_SIM_COLLISION_CHECK("ALL"),
		.C_SINITA_VAL("0"),
		.C_SINITB_VAL("0"),
		.C_USE_BYTE_WEA(0),
		.C_USE_BYTE_WEB(0),
		.C_USE_DEFAULT_DATA(0),
		.C_USE_ECC(0),
		.C_USE_RAMB16BWER_RST_BHV(0),
		.C_WEA_WIDTH(1),
		.C_WEB_WIDTH(1),
		.C_WRITE_DEPTH_A(256),
		.C_WRITE_DEPTH_B(256),
		.C_WRITE_MODE_A("WRITE_FIRST"),
		.C_WRITE_MODE_B("WRITE_FIRST"),
		.C_WRITE_WIDTH_A(64),
		.C_WRITE_WIDTH_B(64),
		.C_XDEVICEFAMILY("virtex2p"))
	inst (
		.CLKA(clka),
		.DINA(dina),
		.ADDRA(addra),
		.WEA(wea),
		.DOUTA(douta),
		.CLKB(clkb),
		.DINB(dinb),
		.ADDRB(addrb),
		.WEB(web),
		.DOUTB(doutb),
		.ENA(),
		.REGCEA(),
		.SSRA(),
		.ENB(),
		.REGCEB(),
		.SSRB(),
		.DBITERR(),
		.SBITERR());
endmodule

