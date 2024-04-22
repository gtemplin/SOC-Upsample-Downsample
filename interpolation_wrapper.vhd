library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;



entity mynewFilter_v1_0 is
	generic (

		-- Parameters of Axi Slave Bus Interface S00_AXIS
		C_S00_AXIS_TDATA_WIDTH	: integer	:= 32;

		-- Parameters of Axi Master Bus Interface M00_AXIS
		C_M00_AXIS_TDATA_WIDTH	: integer	:= 32;
		C_M00_AXIS_START_COUNT	: integer	:= 32
	);
	port (
		-- Users to add ports here

		-- User ports ends
		-- Do not modify the ports beyond this line


		-- Ports of Axi Slave Bus Interface S00_AXIS
		s00_axis_aclk	: in std_logic;
		s00_axis_aresetn	: in std_logic;
		s00_axis_tready	: out std_logic;
		s00_axis_tdata	: in std_logic_vector(C_S00_AXIS_TDATA_WIDTH-1 downto 0);
		s00_axis_tstrb	: in std_logic_vector((C_S00_AXIS_TDATA_WIDTH/8)-1 downto 0);
		s00_axis_tlast	: in std_logic;
		s00_axis_tvalid	: in std_logic;

		-- Ports of Axi Master Bus Interface M00_AXIS
		m00_axis_aclk	: in std_logic;
		m00_axis_aresetn	: in std_logic;
		m00_axis_tvalid	: out std_logic;
		m00_axis_tdata	: out std_logic_vector(C_M00_AXIS_TDATA_WIDTH-1 downto 0);
		m00_axis_tstrb	: out std_logic_vector((C_M00_AXIS_TDATA_WIDTH/8)-1 downto 0);
		m00_axis_tlast	: out std_logic;
		m00_axis_tready	: in std_logic
	);
end mynewFilter_v1_0;

architecture arch_imp of mynewFilter_v1_0 is
-- Interpolation component 
	component bilinear_interpolation is 
		generic(
			OLD_WIDTH            : integer := 64;
			OLD_HEIGHT           : integer := 64; 
			UPSAMPLING_RATE      : integer := 2;
			C_S_AXIS_TDATA_WIDTH : integer := 32
		);
		port (
			clk              : in std_logic;
			rst              : in std_logic;
			DATA_IN_PORT     : in std_logic_vector(31 downto 0);
			DATA_OUT_PORT    : out std_logic_vector(31 downto 0); 
			FILTER_DATA_VALID: out std_logic;
			FILTER_READY_4DATA  : out std_logic;
			run              : in std_logic
		); 
end component;


-- Internal signals 
	signal data_out : std_logic_vector(31 downto 0); 
	signal data_in  : std_logic_vector(31 downto 0); 
	signal run 					: std_logic := '0';
	signal data_available		: std_logic := '0'; 
	signal filter_ready 		: std_logic := '0'; 

begin 
-- Filter I/O ports 
	interpolation_implementation : bilinear_interpolation
		generic map(
			OLD_WIDTH => 64,             -- Default value mapped explicitly
			OLD_HEIGHT => 64,            -- Default value mapped explicitly
			UPSAMPLING_RATE => 2         -- Default value mapped explicitly
		)
		port map(
			clk => s00_axis_aclk,        -- System clock
			rst => s00_axis_aresetn,     -- Asynchronous reset, active low typically
			DATA_IN_PORT => data_in,     -- Input data port
			DATA_OUT_PORT => data_out,   -- Output data port
			FILTER_DATA_VALID => data_available, -- Data valid signal
			FILTER_READY_4DATA => filter_ready, -- Filter ready signal
			run => run                  -- Control signal to start processing
		);


	--- run signal comes from tvalid on the slave (input) 
	run <= s00_axis_tvalid;

	-- The master data is assigned what comes out of the filter
	data_in <= s00_axis_tdata; 
	m00_axis_tdata <= "000000000000000000000000" & data_out(7 downto 0);


-- My handshaking signals 
	m00_axis_tvalid <= data_available; -- only valid output if the filter has output a calcuation 
	s00_axis_tready <= filter_ready; -- only accept input if the filter is ready 

	-- connect through the other AXIS signals from Slave to Master:
	--m00_axis_tvalid <= s00_axis_tvalid;
	m00_axis_tstrb <= s00_axis_tstrb;
	m00_axis_tlast <= s00_axis_tlast;
	--s00_axis_tready <= m00_axis_tready;

end arch_imp;
