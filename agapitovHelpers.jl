@info "Compiling packages for simulation..."
#meta
using TickTock
using ConfParser
using Logging
using Profile
#sim
using Dates
using Random
using OrdinaryDiffEq
using StaticArrays
#process
using JLD2
using Plots
using StatsBase
@info "Packages compiled."


#######################
## Constants n stuff ##
#######################
@info "Loading constants..."
const save_dir = "results_ducting/"
const folder = "run2/"

# case specific
                   #L   MLT  Kp name
const test_cases = [5.1 21.7 3  "ELA_ND_210105T1454"]; # ELA ND 1/05 14:54
                    # 7.1 8.4  2  "ELB_SA_210106T1154"; # ELB SA 1/06 11:54
                    # 6.5 19.8 0  "ELB_ND_210108T0646"; # ELB ND 1/08 06:46
                    # 4.8 19.0 3  "ELA_SD_210111T1750"; # ELA SD 1/11 17:50
                    # 6   8.4  3  "ELA_NA_210112T0226"] # ELA NA 1/12 02:26
const omega_m_cases = [0.2, 0.3, 0.4] # these are the different frequencies to test
L_array = test_cases[:,1]

const numParticles = 32*1200;
const startTime = 0;
const endTime = 4;
tspan = (startTime, endTime); # integration time

const ELo = 50;
const EHi = 2000;
const Esteps = 32; # double ELFIN E bins
const PALo = 4;
const PAHi = 15;
const PAsteps = 1200;
ICrange = [ELo, EHi, Esteps, PALo, PAHi, PAsteps];

const z0 = 0; # start at eq
const λ0 = 0; # start at eq

const lossConeAngle = 4;

const Bw = 1000;  # pT
const a = 3;     # exp(-a * (cos(Φ/dΦ)^2))
const dPhi = 30; # exp(-a * (cos(Φ/dΦ)^2)) number of waves in each packet

const Re   = 6370e3;        # Earth radius, f64
const c    = 3e8;           # speedo lite, f64
const Beq  = 3.e-5;         # B field at equator (T), f64

const saveDecimation = 100000; # really only need first and last point
@info "Done."


function generateFlatParticleDistribution(numParticles::Int64, ICrange, L)
    ELo, EHi, Esteps, PALo, PAHi, PAsteps = ICrange
    @info "Generating a flat particle distribution with"
    @info "$Esteps steps of energy from $ELo KeV to $EHi KeV"
    @info "$PAsteps steps of pitch angles from $PALo deg to $PAHi deg"

    nBins = PAsteps*Esteps
    N = numParticles ÷ nBins # num of particles per bin
    E_bins = logrange(ELo,EHi, Int64(Esteps))
    PA_bins = range(PALo, PAHi, length = Int64(PAsteps))
    @info "Flat distribution with $N particles/bin in $nBins bins"

    if numParticles%nBins != 0
        @warn "Truncating $(numParticles%nBins) particles for an even distribution"
    end
    if iszero(N)
        N = 1;
        @warn "Use higher number of particles next time. Simulating 1 trajectory/bin."
        @warn "Minimum number of particles to simulate is 1 particles/bin."
    end
    
    @views f0 = [[(E+511.)/511. deg2rad(PA)] for PA in PA_bins for E in E_bins for i in 1:N] # creates a 2xN array with initial PA and Energy

    #####       [[z0 pz0                          ζ0               mu0                          λ0 Φ0              ]             ]
    @views h0 = [[z0 sqrt(IC[1]^2 - 1)*cos(IC[2]) rand()*2*pi*dPhi .5*(IC[1]^2-1)*sin(IC[2])^2  λ0 rand()*2*pi*dPhi] for IC in f0] # creates a 5xN array with inital h0 terms
    f0 = vcat(f0...) # convert Array{Array{Float64,2},1} to Array{Float64,2}
    h0 = vcat(h0...) # since i used list comprehension it is now a nested list

    # Other ICs that are important
    # Define basic ICs and parameters
    B0          = Beq*sqrt(1. +3. *sin(λ0)^2.)/L^3.;     # starting B field at eq
    # B0          = B_eq_measured*1e-9                        # measured equatorial field strength
    Omegace0    = (1.6e-19*B0)/(9.11e-31);                    # electron gyrofreq @ the equator
    Omegape     = L;
    @info "Omegape = $Omegape"
    ε           = (Bw*1e-12)/B0;                      # Bw = 300 pT
    η           = Omegace0*L*Re/c;              # should be like 10^3
    @info "L shell of $L w/ wave amplitude of $Bw pT"
    @info "Yields ε = $ε and η = $η"

    resolution  = (1/η) / 20;  # determines max step size of the integrator
    # due to issues accuracy issues around sqrt(mu)~0, experimentally 
    # found that 20x smaller is sufficient to yield stable results
                                                    
    @info "Min integration step of $resolution"
    @info "Created Initial Conditions for $(length(h0[:,1])) particles"
    
    return h0, f0, η, ε, Omegape, resolution;
end

function setup_wave_model(test_cases)
    # take L, MLT, and Kp from test cases
    # return array of functions, normalizers, and coefficients
    wave_model_array = Vector{Function}()
    wave_model_coeff_array = Vector{SVector{4, Float64}}()
    wave_model_normalizer_array = Vector{Float64}()
    for case in eachrow(test_cases)
        wave_model(lambda) = B_w(lambda, case[3], α_ij_matrix(case[1], case[2]))
        push!(wave_model_array, wave_model)
        push!(wave_model_normalizer_array, obtain_normalizer(wave_model))
        push!(wave_model_coeff_array, agapitov_coeffs(case[3], α_ij_matrix(case[1], case[2]))  )
    end  
    return wave_model_array, wave_model_normalizer_array, wave_model_coeff_array
end

function eom!(dH,H,p::SVector{8},t::Float64)
    # These equations define the motion.

    # z, pz, zeta, mu, lambda, phi = H
    # p[1] p[2]     p[3]     p[4]    p[5] p[6]  p[7] p[8]
    # eta, epsilon, Omegape, omegam, a,   dPhi, B_w, B_w_normalizer = p

    sinλ = sin(H[5]);
    cosλ = cos(H[5]);
    g = exp(-p[5] * (cos(H[6]/(2*π*p[6]))^2)) +  exp(-p[5] * (sin(H[6]/(2*π*p[6]))^2))  
    sinζ = g*sin(H[3]);
    cosζ = g*cos(H[3]);
    
    # helper variables
    b = sqrt(1+3*sinλ^2)/(cosλ^6);
    db = (3*(27*sinλ-5*sin(3*H[5])))/(cosλ^8*(4+12*sinλ^2));
    γ = sqrt(1 + H[2]^2 + 2*H[4]*b);
    K = copysign((p[3] * (cosλ^(-5/2)))/sqrt(b/p[4] - 1), H[5]);

    #     eta * epsilon * B_w_normalizer * u * sqrt (2 mu b) / gamma
    psi = p[1] * p[2] * p[8] * (10 ^ abs( p[7][1] * (abs(H[5]) - p[7][4]) * exp(-abs(H[5]) * p[7][3] - p[7][2])) * tanh(H[5])) * sqrt(abs(2*H[4]*b))/γ;

    # actual integration vars
    dH1 = H[2]/γ;
    dH2 = -(H[4]*db)/γ - (psi*cosζ);
    dH3 = p[1]*(K*dH1 - p[4] + b/γ) + (psi*sinζ)/(2*H[4]*K);
    dH4 = -(psi*cosζ)/K;
    dH5 = H[2]/(γ*cosλ*sqrt(1+3*sinλ^2));
    dH6 = p[1]*(K*dH1 - p[4]);

    dH .= SizedVector{6}([ dH1, dH2, dH3, dH4, dH5, dH6 ]);
end

function palostcondition(H,t,integrator)
    # condition: if particle enters loss cone
    b = sqrt(1+3*sin(H[5])^2)/(cos(H[5])^6);
    γ = sqrt(1 + H[2]^2 + 2*H[4]*b);
    return (rad2deg(asin(sqrt( abs((2*H[4])/(γ^2 -1)) )))) < (lossConeAngle/2)
end

function ixlostcondition(H,t,integrator)
    # condition: if I_x approaches 0
    #      2*mu  * b 
    return 2*H[4]*sqrt(1+3*sin(H[5])^2)/(cos(H[5])^6) < 3e-5
end

function eqlostcondition(H,t,integrator)
    # condition: if particle crosses eq in negative direction
    return sign(H[1])==-1 && sign(H[2])==-1
end

affect!(integrator) = terminate!(integrator); # terminate if condition reached
cb1 = DiscreteCallback(palostcondition,affect!);
cb2 = DiscreteCallback(ixlostcondition,affect!);
cb3 = DiscreteCallback(eqlostcondition,affect!);


# Simple calcs
calcb(b::Vector{Float64},λ::Vector{Float64}) = @. b = sqrt(1+3*sin(λ)^2)/(cos(λ)^6)
calcdb(db::Vector{Float64},λ::Vector{Float64}) = @. db = (3*(27*sin(λ)-5*sin(3*λ)))/(cos(λ)^8*(4+12*sin(λ)^2))
calcGamma(γ::Vector{Float64},pz::Vector{Float64},μ::Vector{Float64},b::Vector{Float64}) = @. γ = sqrt(1 + pz^2 + 2*μ*b)
calcK(K::Vector{Float64},b::Vector{Float64},λ::Vector{Float64}) = @. K = (Omegape * (cos(λ)^-(5/2)))/sqrt(b/omegam - 1)
calcAlpha(α::Vector{Float64},μ::Vector{Float64}, γ::Vector{Float64}) = @. α = rad2deg(asin(sqrt((2*μ)/(γ^2 - 1))))

# Useful helpers
logrange(x1, x2, n::Int64) = [10^y for y in range(log10(x1), log10(x2), length=n)]
const E_bins = logrange(ELo,EHi, Int64(Esteps))

obtain_normalizer(f::Function) = maximum(f.(0:0.01:90))^-1

calcb!(b::Vector{Float64}, lambda) = @. b = sqrt(1+3*sin(lambda)^2)/(cos(lambda)^6)
calcGamma!(gamma::Vector{Float64}, pz, mu, b::Vector{Float64}) = @. gamma = sqrt(1 + pz^2 + 2*mu*b)
calcAlpha!(alpha::Vector{Float64}, mu, gamma::Vector{Float64}) = @. alpha = rad2deg(asin(sqrt((2*mu)/(gamma^2 - 1))))



# plot helpers
function extract(sol::EnsembleSolution)
    allZ = Vector{Vector{Float64}}();
    allPZ = Vector{Vector{Float64}}();
    allE = Vector{Vector{Float64}}();
    allPA = Vector{Vector{Float64}}();
    allT = Vector{Vector{Float64}}();
    for traj in sol
    # for i in eachindex(sol)
    #     traj = sol[i];
    #     @info i
        
        vars = Array(traj');
        try
            timesteps = length(traj.t);
            b = zeros(timesteps);
            gamma = zeros(timesteps);
            Alpha = zeros(timesteps);

            @views calcb!(b,vars[:,5]);
            @views calcGamma!(gamma,vars[:,2],vars[:,4],b);
            @views calcAlpha!(Alpha,vars[:,4],gamma);
            @views push!(allT, traj.t);
            @views push!(allZ, vars[:,1]);
            @views push!(allPZ, vars[:,2]);
            @views push!(allPA, Alpha);
            @views push!(allE, @. (511*(gamma - 1)));
        catch
            last_positive_index = minimum(findall(x->x<=0,vars[:,4])) -1 
            @info "Caught negative mu"
            @info "index $(length(vars[:,4])-last_positive_index) from end"

            timesteps = length(traj.t[1:last_positive_index]);
            b = zeros(timesteps);
            gamma = zeros(timesteps);
            Alpha = zeros(timesteps);

            @views calcb!(b,vars[1:last_positive_index,5]);
            @views calcGamma!(gamma,vars[1:last_positive_index,2],vars[1:last_positive_index,4],b);
            @views calcAlpha!(Alpha,vars[1:last_positive_index,4],gamma);
            @views push!(allT, traj.t[1:last_positive_index]);
            @views push!(allZ, vars[1:last_positive_index,1]);
            @views push!(allPZ, vars[1:last_positive_index,2]);
            @views push!(allPA, Alpha);
            @views push!(allE, @. (511*(gamma - 1)));
        end

    end
    @info "$(length(sol)) particles loaded in..."
    return allT, allZ, allPZ, allE, allPA;
end

function postProcessor(allT::Vector{Vector{Float64}}, allZ::Vector{Vector{Float64}}, allPZ::Vector{Vector{Float64}}, allE::Vector{Vector{Float64}}, allPA::Vector{Vector{Float64}})
    #=
    This function will take the output of the model and convert them into usable m x n matrices
    where m is max number of timesteps for the longest trajectory and N is number of particles
    Arrays that are not m long are filled with NaNs
    =#
    N = length(allT); # num particles from data
    tVec = allT[findall(i->i==maximum(length.(allT)),length.(allT))[1]]; # turns all time vectors into a single time vector spanning over the longest trajectory
    timeseriesLength = length(tVec); # all vectors must be this tall to ride
    Zmatrix = fill(NaN,timeseriesLength,N); 
    PZmatrix = fill(NaN,timeseriesLength,N); 
    Ematrix = fill(NaN,timeseriesLength,N); 
    PAmatrix = fill(NaN,timeseriesLength,N); 
    # iterate over each matrix column and fill with each vector
    for i = 1:N
        @views Zmatrix[1:length(allT[i]),i] = allZ[i]
        @views PZmatrix[1:length(allT[i]),i] = allPZ[i]
        @views Ematrix[1:length(allT[i]),i] = allE[i]
        @views PAmatrix[1:length(allT[i]),i] = allPA[i]
    end
    @info "Matrices generated..."
    return tVec, Zmatrix, PZmatrix, Ematrix, PAmatrix
end

function countLostParticles(allT::Vector{Vector{Float64}}, endTime::Float64)
    #=
    Based on time vectors, counts which ones were lost
    and at what time. Returns a Nx2 array where the first
    column is the time at which the particle was lost, and
    the 2nd column denotes the number lost at that point.
    =#
    lossCounter = []; # initialize vector

    for ntime in allT # loop thru each particle
        if maximum(ntime) != endTime # particle lost if ended early
            push!(lossCounter, maximum(ntime)); # the final entry in the time vector is when the particle got lost
        end
    end
    if isempty(lossCounter) # if particle wasn't lost, then throw in a NaN
        push!(lossCounter, NaN) 
        @warn "All particles trapped!" # since all particles trapped
    end
    lostParticles = [sort(lossCounter) collect(1:length(lossCounter))] # sort it by time, so you can see when particles got lost

    if maximum(lostParticles[:,1]) != endTime # this adds in a final hline from last particle lost to end of simulation
        lostParticles = vcat(lostParticles, [endTime (maximum(lostParticles[:,2]))]);
    end 

    @info "Total of $(lostParticles[end,end]) particles lost during sim"
    return lostParticles
end
struct Resultant_Matrix
    label::String
    numParticles::Int64
    endTime::Float64
    allZ::Vector{Vector{Float64}}
    allPZ::Vector{Vector{Float64}}
    allT::Vector{Vector{Float64}}
    allPA::Vector{Vector{Float64}}
    allE::Vector{Vector{Float64}}
    lostParticles::Matrix{Float64}
    tVec::Vector{Float64}
    Zmatrix::Matrix{Float64}
    PZmatrix::Matrix{Float64}
    Ematrix::Matrix{Float64}
    PAmatrix::Matrix{Float64}
end

function sol2rm(sol, label)
    allT, allZ, allPZ, allE, allPA = extract(sol);
    tVec, Zmatrix, PZmatrix, PAmatrix, Ematrix = postProcessor(allT, allZ, allPZ, allPA, allE);
    return Resultant_Matrix(label, length(sol), tVec[end], allZ, allPZ, allT, allPA, allE,countLostParticles(allT, tVec[end]), tVec, Zmatrix, PZmatrix, Ematrix, PAmatrix)
end