module LIF_Model #(
    parameter T = 8,  // Number of time steps
    parameter Q = 10   // Bits for quantization
) (
    input wire result_val,
    input wire        clk,
    input wire        rst_n,
    input wire        start,             // Added start signal to begin processing
    input wire [T*Q-1:0] input_data,     // Changed to bit vector
    input wire [Q-1:0] threshold,        // Firing threshold
    output reg [T-1:0] spike_out,        // Output spikes for T time steps
    output wire        lif_done           // Done signal
);
    // State definitions
    parameter IDLE = 2'b00;
    parameter CALC = 2'b01;
    parameter DONE = 2'b10;
    
    reg [1:0] current_state, next_state;
    
    reg [Q-1:0] membrane_potential;
    reg [$clog2(T):0] timestep; // Counter to track current timestep
    reg [Q-1:0] next_potential;
    reg [Q-1:0] current_input;
    
    // Next state logic
    always @(*) begin
        next_state = current_state;
        
        case (current_state)
            IDLE: begin
                if (start & result_val)
                    next_state = CALC;
            end
            
            CALC: begin
                if (timestep == T)
                    next_state = DONE;
            end
            
            DONE: begin
                next_state = IDLE;
            end
            
            default: next_state = IDLE;
        endcase
    end
    
    // Extract the current input from the bit vector
    always @(*) begin
        current_input = input_data[((timestep+1)*Q-1) -: Q];
    end
    
    // State register and timestep counter
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_state <= IDLE;
            timestep <= 0;
            membrane_potential <= 0;
            spike_out <= 0;
        end else begin
            current_state <= next_state;
            
            case (current_state)
                IDLE: begin
                    timestep <= 0;
                    if (start)
                        membrane_potential <= 0;
                end
                
                CALC: begin
                    if (timestep < T) begin
                        // Calculate next potential
                        if (timestep == 0) 
                            next_potential = membrane_potential + current_input;
                        else 
                            next_potential = spike_out[timestep-1] ? current_input : 
                                                                   (membrane_potential + current_input);
                        
                        // Check threshold and generate spike
                        spike_out[timestep] <= (next_potential > threshold);
                        
                        // Update membrane potential
                        membrane_potential <= next_potential;
                        
                        // Increment timestep
                        timestep <= timestep + 1;
                    end
                end
                
                DONE: begin
                    // Reset will occur on next IDLE state
                end
            endcase
        end
    end
    
    // Output logic for done signal
    assign lif_done = (current_state == DONE);
    
endmodule
