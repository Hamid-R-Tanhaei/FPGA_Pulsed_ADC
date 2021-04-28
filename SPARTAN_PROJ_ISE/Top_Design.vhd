----------------------------------------------------------------------------------
-- Company: 
-- Engineer: Hamid Reza Tanhaei
-- 
-- Create Date:    13:29:59 01/18/2021 
-- Design Name: 
-- Module Name:    FPGA_Pulsed_ADC - Behavioral 
-- Project Name: 
-- Target Devices:  XC6SLX9-2TQG144
-- Tool versions: 
-- Description: 
--
-- Dependencies: 
--
-- Revision: 
-- Revision 0.01 - File Created
-- Additional Comments: 
--
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
---------------------
entity Top_Design is
    Port ( 
			CLK_IN 		: in  	STD_LOGIC;

			ESP32_Data 	: out  	std_logic_vector(7 downto 0);
			ESP32_Ready : in  	STD_LOGIC;
			ESP32_clk 	: in  	STD_LOGIC;
			
			In_sig_pin	: in	std_logic
			);
end Top_Design;
----------------------------------------
architecture Behavioral of Top_Design is
	------------------------------------
	signal	RAM1_WAddr	: std_logic_vector(9 downto 0) := (others=>'0');
	signal	RAM1_RAddr	: std_logic_vector(9 downto 0) := (others=>'0');
	signal	RAM1_WData	: std_logic_vector(9 downto 0) 	:= (others=>'0');
	signal	RAM1_RData	: std_logic_vector(9 downto 0) 	:= (others=>'0');
	signal	RAM1_WE		: std_logic_vector(0 downto 0) 	:= "0";
	------------------------------------------------
	-- control/timing signals:
	signal	ADC_Scan_En 		: 	std_logic := '0';
	signal	CLK_50M, CLK_100M, CLK_5M	:	std_logic;
	signal	Timer_cntr : unsigned(18 downto 0) := (others => '0');
	---------------------------------------------
	-- Signals: Monitoring through esp32 
	signal	esp_rdy_cur, esp_rdy_pre  : std_logic := '0';
	signal	esp_clk_cur, esp_clk_pre  : std_logic := '0';
	signal	Monitoring_en	: std_logic := '0';
	signal 	ESP_Data_out : std_logic_vector(7 downto 0):= (others => '0');
	-----------------------------------------------
	signal	In_sig_integral : signed(16 downto 0) := (others => '0');
	signal	Input_signal_regd : std_logic := '0';
	signal	MAF_Acc : signed(23 downto 0) := (others => '0');
	signal	MAF_Back : signed(22 downto 0) := (others => '0');
	signal	back_avger : signed(15 downto 0) := (others => '0');
	signal	back_value_inst, back_step : signed(12 downto 0) := (others => '0');
	---------------------------------------------------------
	--signal  fir1_delay, fir1_in_zero : std_logic := '0';
	--------------------
	signal	FIR0_rfd, FIR0_rdy : std_logic := '0';
	signal	FIR0_din, FIR0_dout : std_logic_vector(15 downto 0) := (others => '0');
	signal	sample_cntr : unsigned(9 downto 0) := (others => '0');
----------------
component DCM_Pre
port
 (-- Clock in ports
  CLK_OSC_IN	: in     std_logic;
  -- Clock out ports
  CLK_OUT_50M   : out    std_logic;
  CLK_OUT_100M  : out    std_logic;
  CLK_OUT_5M    : out    std_logic;
  CLK_VALID     : out    std_logic
 );
end component;
--------------------------
component FIR_0
	port (
	clk: in std_logic;
	rfd: out std_logic;
	rdy: out std_logic;
	din: in std_logic_vector(15 downto 0);
	dout: out std_logic_vector(15 downto 0));
end component;
------------------------------
-----------------------------------------------
COMPONENT RAM_Block
  PORT (
    clka : IN STD_LOGIC;
    ena : IN STD_LOGIC;
    wea : IN STD_LOGIC_VECTOR(0 DOWNTO 0);
    addra : IN STD_LOGIC_VECTOR(9 DOWNTO 0);
    dina : IN STD_LOGIC_VECTOR(9 DOWNTO 0);
    clkb : IN STD_LOGIC;
    addrb : IN STD_LOGIC_VECTOR(9 DOWNTO 0);
    doutb : OUT STD_LOGIC_VECTOR(9 DOWNTO 0)
  );
END COMPONENT;
----------------------------------------------
----------------------------------------------
begin
-------------------------------------------
	ESP32_Data 	<= ESP_Data_out;
	------------------------------------------------------------------------
	process(CLK_50M) --50 MHz from DCM
	begin
		if rising_edge(CLK_50M)  then
			RAM1_WE	<= "0";
			----------------------------------------------------------
			-- Timing handler:
			Timer_cntr <= Timer_cntr + 1;
			
			if (Timer_cntr = to_unsigned(0, 19)) then -- Triggering scan process every ~10ms
				MAF_Back <= (others => '0');
				MAF_Acc <= (others => '0');
				In_sig_integral <= (others => '0');
				ADC_Scan_En <= '1';
				sample_cntr <= (others => '0');
			end if;
			
			-----------------------
			Input_signal_regd <= In_sig_pin;
			if (ADC_Scan_En = '1') then
				if (Input_signal_regd = '1') then
					In_sig_integral <= In_sig_integral + 1; -- bitwidth:17
				else
					In_sig_integral <= In_sig_integral - 1;
				end if;
				-- Accumulating input pulse (Integrator)
				MAF_Acc <= MAF_Acc + In_sig_integral; --Accumulating 98 successive samples
				-- Accumulating background value for Compensating undesired slope
				MAF_Back <= MAF_Back - In_sig_integral; --Accumulating 98 successive samples
				
				if (FIR0_rfd = '1') then -- downsampling: every 98 clks : 50000/98 => 512KHz (actual sampling frequency)
					FIR0_din <= std_logic_vector(resize(MAF_Acc(23 downto 4), 16));
					-- Initializing signal accumulator for compensating undesired slope
					MAF_Acc	<=	back_step * signed('0' & sample_cntr);
					MAF_Back <= (others => '0');
					back_value_inst <= MAF_Back(22 downto 10);
					sample_cntr <= sample_cntr + 1;
					if (sample_cntr = to_unsigned(1023, 10)) then -- 1024*1.95us => 2ms sampling
						back_step <= back_value_inst;
						ADC_Scan_En <= '0';
					end if;
				end if;
				if (FIR0_rdy = '1') then
					RAM1_WData <= (FIR0_dout(15) & FIR0_dout(8 downto 0));
					RAM1_WAddr <= std_logic_vector(sample_cntr);
					RAM1_WE	<= "1";
				end if;
			else
				fir0_din	<= (others => '0');
			end if;
			------------------------------------
			-- Monitoring: Interaction with ESP32 
			esp_rdy_cur	<=	ESP32_Ready;
			esp_rdy_pre	<=	esp_rdy_cur;
			esp_clk_cur	<=	ESP32_clk;
			esp_clk_pre	<=	esp_clk_cur;
			if ((esp_rdy_pre = '1') and (esp_clk_cur = '1') and (esp_clk_pre = '0')) then -- rising edge
				RAM1_RAddr 		<= 	std_logic_vector(unsigned(RAM1_RAddr) + 1);
				ESP_Data_out	<=	RAM1_RData(9 downto 2);
			end if;
			if ((esp_rdy_cur = '1') and (esp_rdy_pre = '0')) then -- rising edge
				RAM1_RAddr <= (others => '0');
			end if;
		------------------------------------------------------------------------
		end if;
	end process;
---------------------------------
inst_Pre_DCM : DCM_Pre
  port map
   (-- Clock in ports
    CLK_OSC_IN => CLK_IN,
    -- Clock out ports
    CLK_OUT_50M => CLK_50M,
    CLK_OUT_100M => CLK_100M,
    CLK_OUT_5M => CLK_5M,
    CLK_VALID => open
	);
--------------------------------------
inst_fir_filter_0 : FIR_0
  port map (
	clk => CLK_50M,
	rfd => FIR0_rfd,
	rdy => FIR0_rdy,
	din => FIR0_din,
	dout => FIR0_dout
	);
--------------------------------------
----------------------------------------
inst_RAM_block1 : RAM_Block
  PORT MAP (
    clka => CLK_50M,
    ena => '1',
    wea => RAM1_WE,
    addra => RAM1_WAddr,
    dina => RAM1_WData,
    clkb => CLK_50M,
    addrb => RAM1_RAddr,
    doutb => RAM1_RData
  );
-----------------------------------------
-------------------------------------
end Behavioral;

