library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all; --package needed for signed

-- Upsample 64x64 to 128x128 
-- Update generics for other dimensions 

----------------------------------------------------------------------------------------------------------------------------------
entity bilinear_interpolation is
	generic(		
		OLD_WIDTH				: integer 	:= 64;
		OLD_HEIGHT				: integer 	:= 64; 
		UPSAMPLING_RATE			: integer 	:= 2); -- how many times bigger the upsampled image is 
	
    port (
        clk              : in std_logic;
        rst              : in std_logic;
        DATA_IN_PORT     : in std_logic_vector(31 downto 0);
        DATA_OUT_PORT    : out std_logic_vector(31 downto 0); 
        FILTER_DATA_VALID: out std_logic;
        FILTER_READY_4DATA  : out std_logic;
        run              : in std_logic); 
end entity;


architecture bilinear_behavior of bilinear_interpolation is 
	constant new_width 			: integer := OLD_WIDTH * UPSAMPLING_RATE;
	constant new_height 		: integer := OLD_HEIGHT * UPSAMPLING_RATE; 
	constant pixels_in_buffer 	: integer := OLD_WIDTH * 2; -- how many pixels are stored in the two-line buffer
	constant pixels_in_output  	: integer := new_width * 2; -- how many pixels should be output per calculation cycle 
	signal lines_input 			: integer := 0; 
	signal pixels_input			: integer := 0; 
	signal calculated_lines 	: integer := 0;
	signal calculated_pixels 	: integer := 0; 
	signal data_out 			: unsigned(31 downto 0); 
	signal data_in 				: unsigned(31 downto 0); 
	signal data_available		: std_logic;
	signal ready_for_data 		: std_logic;  
	type one_line_buffer is array (0 to OLD_WIDTH-1) of std_logic_vector(7 downto 0);
	type two_line_buffer is array (0 to (OLD_WIDTH*2)-1) of std_logic_vector(7 downto 0);
	signal two_lines : two_line_buffer; 
	type State_Type is (Idle, Loading, Calculating, Done); 
	signal state, next_state : State_Type; 
	signal total_output_counter : integer := 0; 
	

	-- pass this function the # of pixels output when using this two-line buffer for calculations 
	-- it will return a pixel value estimate based on where you are 
	-- ensure that the output counter is incremented after calling it 
	impure function get_output_pixel(output_counter : integer; pixel_buffer : two_line_buffer) return integer is 
		variable top_line_original, bottom_line_original : one_line_buffer;
		-- variables to help find the closest pixels in the original 
		variable output_line_counter : integer;
		variable line_from_original : integer; 
		variable v_weight_num, v_weight_den : integer; 
		variable v_weight_scaled, v_weight_opposite_scaled : integer; 
		-- closest pixels in original, and weights based on 
		variable pixel_from_original, next_pixel : integer; 
		variable h_weight_num, h_weight_den : integer; 
		variable h_weight_scaled, h_weight_opposite_scaled : integer; 
		-- pixel values referenced to compute an estimate 
		variable pix1, pix2, pix3, pix4 : integer; 
		variable h_upper_est, h_lower_est : integer;
		variable output_pixel : integer := 0; 
	
	begin 
		-- get the top/bottom lines from the two-line buffer 
		for i in 0 to OLD_WIDTH - 1 loop
		    for j in 7 downto 0 loop 
		        bottom_line_original(i)(j) := two_lines(i)(j);
		    end loop; 
        end loop;       
        for i in 0 to OLD_WIDTH - 1 loop
            for j in 7 downto 0 loop 
		        bottom_line_original(i)(j) := two_lines(i + OLD_WIDTH)(j);
		    end loop;
        end loop;

		-- determine which new output line you are on 
		output_line_counter := output_counter / new_width; 
		-- use that to determine the line from the original to use 
		line_from_original := output_line_counter * OLD_HEIGHT / new_height;
		-- use that to calculate the vertical weights 
		v_weight_num := output_line_counter * OLD_HEIGHT mod new_height;
		v_weight_den := new_height; 
		v_weight_scaled := 1000 * v_weight_num / v_weight_den;
		v_weight_opposite_scaled := 1000 - v_weight_scaled;

		-- determine which pixels from the original should be used for the calculation 
		pixel_from_original := (output_counter mod new_width) * OLD_WIDTH / new_width;
		if (pixel_from_original+1) >= (OLD_WIDTH-1) then 
			next_pixel := pixel_from_original;
		else 
			next_pixel := pixel_from_original + 1; 
		end if;
		-- use that to calculate the horizontal weights 
		h_weight_num := (output_counter mod new_width) * OLD_WIDTH mod new_width;
		h_weight_den := new_width; 
		h_weight_scaled := 1000 * h_weight_num / h_weight_den;
		h_weight_opposite_scaled := 1000 - h_weight_scaled;

		-- Get the pixel values to used based on the line/pixel from the original desired 
		-- | 1 | 2 |
		-- | 3 | 4 | 
		pix1 := to_integer(unsigned(top_line_original(pixel_from_original))); 
		pix2 := to_integer(unsigned(top_line_original(pixel_from_original+1))); 
		pix3 := to_integer(unsigned(bottom_line_original(pixel_from_original))); 
		pix4 := to_integer(unsigned(bottom_line_original(pixel_from_original+1))); 

		-- use the horizontal weights and locations found above to determine the horizontal estimates 
		h_upper_est := (pix1 * h_weight_scaled + pix2 * h_weight_opposite_scaled) / 1000; 
		h_lower_est := (pix3 * h_weight_scaled + pix4 * h_weight_opposite_scaled) / 1000; 
		-- use the vertical weights and locations, along w/ horizontal estimates, to get the final output estimate 
		output_pixel := (h_upper_est * v_weight_scaled + h_lower_est * v_weight_opposite_scaled);

		-- return the estimated pixel value 
		return output_pixel; 
	end function get_output_pixel;



begin
-- I/O signal assignments 
	data_in <= unsigned(DATA_IN_PORT); 
	FILTER_DATA_VALID <= data_available; 
	FILTER_READY_4DATA <= ready_for_data;


-- Main process starts here: 
	process(clk, rst) 
		variable calculated_output_pixel : integer := 0; 
		variable temp_pixel_counter : integer := 0; -- used by Loading state for coordination 
	begin 		
		if rising_edge(clk) then 
----------------------------------------------------------------------------------------------
			case state is
			when Idle =>
				if run='1' then 
					data_available <= '0'; 
                    ready_for_data <= '1'; 
                    lines_input <= 0;
                    pixels_input <= 0; 
                    calculated_lines <= 0; 
                    calculated_pixels <= 0; 
                    total_output_counter <= 0;  
				else
					next_state <= Idle; 
					data_available <= '0';
					ready_for_data <= '0'; 
				end if;
				
----------------------------------------------------------------------------------------------
			when Loading =>
			-- First determine if the total number of outputs is the new image size
			-- Otherwise, when valid data input, place it into the buffer 
			if total_output_counter >= (new_height*new_width) then 
					next_state <= Done;
					data_available <= '0'; 
					ready_for_data <= '0'; 
					data_out <= (others => '0');
					temp_pixel_counter := -1; -- set to zero to ensure that the Calculating state is not entered 
			elsif run='1' then 
				-- shift register buffer 
				two_lines(1 to (OLD_WIDTH*2)-1) <= two_lines(0 to (OLD_WIDTH*2)-2);
				two_lines(0) <= std_logic_vector(data_in(7 downto 0));
				pixels_input <= pixels_input + 1; 
				-- Determine the next state 
				temp_pixel_counter := pixels_input + 1; 
				if temp_pixel_counter=pixels_in_buffer then 
					next_state <= Calculating;
					calculated_lines <= 0;
					calculated_pixels <= 0;
				else 
					next_state <= Loading; 
					data_available <= '0'; 
					ready_for_data <= '1'; 
				end if; 
				data_out <= (others => '0'); -- blank output data before line buffers load	
			end if;   
			
----------------------------------------------------------------------------------------------
			when Calculating => 
			-- Pass this function the current pixel counter and the loaded buffer
				calculated_output_pixel := get_output_pixel(calculated_pixels, two_lines); 
				calculated_pixels <= calculated_pixels + 1; 

			-- Regardless of anything, output the calculated pixel 
				data_out(7 downto 0) <= to_unsigned(calculated_output_pixel, 8); 
				data_out(31 downto 8) <= (others => '0'); 
				total_output_counter <= total_output_counter + 1; 
			
			-- determine if the number of lines required has been output 
				if calculated_pixels = (UPSAMPLING_RATE * new_width - 1) then 
					next_state <= Loading;
					lines_input <= 0;
					pixels_input <= 0; 
					data_available <= '0'; 
					ready_for_data <= '1'; 
				else 
					next_state <= Calculating; 
					data_available <= '1';
					ready_for_data <= '0'; 
				end if;
	
----------------------------------------------------------------------------------------------
        	when Done =>
			-- do a reset on all signals and go idle 
				data_available <= '0'; 
				ready_for_data <= '1'; 
				lines_input <= 0;
				pixels_input <= 0; 
				calculated_lines <= 0; 
				calculated_pixels <= 0; 
				total_output_counter <= 0; 
				next_state <= Idle; 
----------------------------------------------------------------------------------------------
        	when others =>
				next_state <= Idle; 
----------------------------------------------------------------------------------------------
    		end case;
			state <= next_state;
----------------------------------------------------------------------------------------------		
		end if; 

		-- Registered output 
		if rising_edge(clk) then 
			DATA_OUT_PORT <= std_logic_vector(data_out);
		end if; 

	end process; 

end bilinear_behavior; 
