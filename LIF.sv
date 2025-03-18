module LIF_Model #(
    parameter T = 8,  // Number of time steps
    parameter Q = 8   // Bits for quantization
) (
    input logic result_val,
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,             // Added start signal to begin processing
    input  logic [Q-1:0] input_data [T-1:0], // Input data for T time steps
    input  logic [Q-1:0] threshold,          // Firing threshold
    output logic [T-1:0] spike_out,          // Output spikes for T time steps
    output logic        lif_done            // Done signal
);
    // State definitions
    typedef enum logic [1:0] {
        IDLE = 2'b00,
        CALC = 2'b01,
        DONE = 2'b10
    } state_t;
    
    state_t current_state, next_state;
    
    logic [Q-1:0] membrane_potential;
    logic [$clog2(T):0] timestep; // Counter to track current timestep
    logic [Q-1:0] next_potential;
    
    // Next state logic
    always_comb begin
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
    
    // State register and timestep counter
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_state <= IDLE;
            timestep <= '0;
            membrane_potential <= '0;
            spike_out <= '0;
        end else begin
            current_state <= next_state;
            
            case (current_state)
                IDLE: begin
                    timestep <= '0;
                    if (start)
                        membrane_potential <= '0;
                end
                
                CALC: begin
                    if (timestep < T) begin
                        // Calculate next potential
                        if (timestep == 0) 
                            next_potential = membrane_potential + input_data[timestep];
                        else 
                            next_potential = spike_out[timestep-1] ? input_data[timestep] : 
                                                                   (membrane_potential + input_data[timestep]);
                        
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
    always_comb begin
        lif_done = (current_state == DONE);
    end
    
endmodule