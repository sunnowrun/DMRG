# function _eig_solver(f, x, maxiter::Int, tol::Real; verbosity::Int=0)
# 	eigenvalue, eigenvec, info = simple_lanczos_solver(f, x, "SR", maxiter, tol, verbosity=verbosity)
# 	return eigenvalue, eigenvec
# end

function _eig_solver(h, init, maxiter, tol)
	if dim(init) >= 20
		eigenvalue_0, eigenvec_0, info = simple_lanczos_solver(h, init, "SR", maxiter, tol, verbosity=0)
	else
		init = TensorMap(randn, scalartype(init), space(init))
		# eigenvalues, eigenvecs, infos = eigsolve(h, init, 1, :SR, Lanczos(; maxiter=maxiter, tol=tol, eager=true))
		eigenvalues, eigenvecs, infos = eigsolve(h, init, 1, :SR, Lanczos())
		# (infos.converged >= 1) 
		eigenvalue_0 = eigenvalues[1]
		eigenvec_0 = eigenvecs[1]
	end
	return eigenvalue_0, eigenvec_0
end

@with_kw struct DMRG1 <: DMRGAlgorithm 
	D::Int = Defaults.D
	tolgauge::Float64 = Defaults.tolgauge
	maxiter::Int = Defaults.maxiter
	tol::Float64 = Defaults.tol
	maxitereig::Int = 10
	toleig::Float64 = Defaults.tollanczos
	verbosity::Int = Defaults.verbosity
	callback::Function = Returns(nothing)
end

function Base.getproperty(x::DMRG1, s::Symbol)
	if s == :trunc
		return truncdimcutoff(D=x.D, ϵ=x.tolgauge, add_back=0)
	else
		getfield(x, s)
	end
end

Base.similar(x::DMRG1; D::Int=x.D, tolgauge::Float64=x.tolgauge, maxiter::Int=x.maxiter, tol::Float64=x.tol, maxitereig::Int=x.maxitereig, 
			toleig::Float64=x.toleig, verbosity::Int=x.verbosity, callback::Function=x.callback) = DMRG1(
			D=D, tolgauge=tolgauge, maxiter=maxiter, tol=tol, maxitereig=maxitereig, toleig=toleig, verbosity=verbosity, callback=callback)

function calc_galerkin(m::Union{ExpectationCache, ProjectedExpectationCache}, site::Int)
	mpsj = m.mps[site]
	try
		return norm(leftnull(mpsj)' * ac_prime(mpsj, m.mpo[site], m.hstorage[site], m.hstorage[site+1]))
	catch
		return norm(permute(ac_prime(mpsj, m.mpo[site], m.hstorage[site], m.hstorage[site+1]), (1,), (2,3)) * rightnull(permute(mpsj, (1,), (2,3) ) )' )
	end
end

# delayed evaluation of galerkin error.
function leftsweep!(m::ExpectationCache, alg::DMRG1)
	# try increase the bond dimension if the bond dimension of the state is less than D given by alg
	# increase_bond!(m, D=alg.D)
	mpo = m.mpo
	mps = m.mps
	hstorage = m.env
	Energies = Float64[]
	delta = 0.
	for site in 1:length(mps)-1
		(alg.verbosity > 3) && println("sweeping from left to right at site: $site.")
		# eigvals, vecs = eigsolve(x->ac_prime(x, mpo[site], hstorage[site], hstorage[site+1]), mps[site], 1, :SR, Lanczos(), 
		# 	tol=alg.toleig, maxiter=alg.maxitereig)
		eigvals, vecs = _eig_solver(x->ac_prime(x, mpo[site], hstorage[site], hstorage[site+1]), mps[site], alg.maxitereig, alg.toleig)
		push!(Energies, eigvals)
		(alg.verbosity > 2) && println("Energy after optimization on site $site is $(Energies[end]).")
		# galerkin error
		delta = max(delta, calc_galerkin(m, site) )
		# prepare mps site tensor to be left canonical
		Q, R = leftorth!(vecs, alg=QR())
		mps[site] = Q
		mps[site+1] = @tensor tmp[-1 -2; -3] := R[-1, 1] * mps[site+1][1, -2, -3]
		# hstorage[site+1] = updateleft(hstorage[site], mps[site], mpo[site], mps[site])
		updateleft!(m, site)
	end
	return Energies, delta
end

function rightsweep!(m::ExpectationCache, alg::DMRG1)
	mpo = m.mpo
	mps = m.mps
	hstorage = m.env
	Energies = Float64[]
	delta = 0.
	for site in length(mps):-1:2
		(alg.verbosity > 3) && println("sweeping from right to left at site: $site.")
		# eigvals, vecs = eigsolve(x->ac_prime(x, mpo[site], hstorage[site], hstorage[site+1]), mps[site], 1, :SR, Lanczos())
		eigvals, vecs = _eig_solver(x->ac_prime(x, mpo[site], hstorage[site], hstorage[site+1]), mps[site], alg.maxitereig, alg.toleig)
		push!(Energies, eigvals)
		(alg.verbosity > 2) && println("Energy after optimization on site $site is $(Energies[end]).")		
		# galerkin error
		delta = max(delta, calc_galerkin(m, site) )
		# prepare mps site tensor to be right canonical
		L, Q = rightorth(vecs, (1,), (2,3), alg=LQ())
		mps[site] = permute(Q, (1,2), (3,))
		mps[site-1] = @tensor tmp[-1 -2; -3] := mps[site-1][-1, -2, 1] * L[1, -3]
		# hstorage[site] = updateright(hstorage[site+1], mps[site], mpo[site], mps[site])
		updateright!(m, site)
	end
	return Energies, delta
end


@with_kw struct DMRG2 <: DMRGAlgorithm
	maxiter::Int = Defaults.maxiter
	tol::Float64 = Defaults.tol	
	maxitereig::Int = 10
	toleig::Float64 = Defaults.tollanczos
	verbosity::Int = Defaults.verbosity
	trunc::TruncationDimCutoff = DefaultTruncation
end

Base.similar(x::DMRG2; trunc::TruncationDimCutoff=x.trunc, maxiter::Int=x.maxiter, tol::Float64=x.tol, maxitereig::Int=x.maxitereig, toleig::Float64=x.toleig, verbosity::Int=x.verbosity) = DMRG2(
			trunc=trunc, maxiter=maxiter, tol=tol, maxitereig=maxitereig, toleig=toleig, verbosity=verbosity)

function Base.getproperty(x::DMRG2, s::Symbol)
	if s == :D
		return x.trunc.D
	elseif s == :ϵ
		return x.trunc.ϵ
	else
		getfield(x, s)
	end
end

function leftsweep!(m::ExpectationCache, alg::DMRG2)
	mpo = m.mpo
	mps = m.mps
	hstorage = m.env
	trunc = alg.trunc
	Energies = Float64[]
	delta = 0.
	for site in 1:length(mps)-2
		(alg.verbosity > 3) && println("sweeping from left to right at bond: $site.")
		@tensor twositemps[-1 -2; -3 -4] := mps[site][-1, -2, 1] * mps[site+1][1, -3, -4]
		# eigvals, vecs = eigsolve(x->ac2_prime(x, mpo[site], mpo[site+1], hstorage[site], hstorage[site+2]), twositemps, 1, :SR, Lanczos())
		eigvals, vecs = _eig_solver(x->ac2_prime(x, mpo[site], mpo[site+1], hstorage[site], hstorage[site+2]), twositemps, alg.maxitereig, alg.toleig)
		push!(Energies, eigvals)
		(alg.verbosity > 2) && println("Energy after optimization on bond $site is $(Energies[end]).")				
		# prepare mps site tensor to be left canonical
		u, s, v, err = stable_tsvd!(vecs, trunc=trunc)
		normalize!(s)
		mps[site] = u
		v = s * v
		mps[site+1] = permute(v, (1,2), (3,))
		# compute error
		err_1 = @tensor twositemps[1,2,3,4]*conj(u[1,2,5])*conj(v[5,3,4])
        delta = max(delta,abs(1-abs(err_1)))
		# hstorage[site+1] = updateleft(hstorage[site], mps[site], mpo[site], mps[site])
		updateleft!(m, site)
	end
	return Energies, delta
end

function rightsweep!(m::ExpectationCache, alg::DMRG2)
	mpo = m.mpo
	mps = m.mps
	hstorage = m.env
	trunc = alg.trunc
	Energies = Float64[]
	delta = 0.
	for site in length(mps)-1:-1:1
		(alg.verbosity > 3) && println("sweeping from right to left at bond: $site.")
		@tensor twositemps[-1 -2; -3 -4] := mps[site][-1, -2, 1] * mps[site+1][1, -3, -4]
		# eigvals, vecs = eigsolve(x->ac2_prime(x, mpo[site], mpo[site+1], hstorage[site], hstorage[site+2]), twositemps, 1, :SR, Lanczos())
		eigvals, vecs = _eig_solver(x->ac2_prime(x, mpo[site], mpo[site+1], hstorage[site], hstorage[site+2]), twositemps, alg.maxitereig, alg.toleig)
		push!(Energies, eigvals)
		(alg.verbosity > 2) && println("Energy after optimization on bond $site is $(Energies[end]).")	
		# prepare mps site tensor to be right canonical
		u, s, v, err = stable_tsvd!(vecs, trunc=trunc)	
		normalize!(s)
		u = u * s
		mps[site] = u 
		mps[site+1] = permute(v, (1,2), (3,))
		mps.s[site+1] = s
		# compute error
		err_1 = @tensor twositemps[1,2,3,4]*conj(u[1,2,5])*conj(v[5,3,4])
        delta = max(delta,abs(1-abs(err_1)))
		# hstorage[site+1] = updateright(hstorage[site+2], mps[site+1], mpo[site+1], mps[site+1])
		updateright!(m, site+1)
	end
	return Energies, delta
end



@with_kw  struct DMRG1S{E<:SubspaceExpansionScheme} <: DMRGAlgorithm
	maxiter::Int = Defaults.maxiter
	tol::Float64 = Defaults.tol	
	maxitereig::Int = 10
	toleig::Float64 = Defaults.tollanczos
	verbosity::Int = Defaults.verbosity
	trunc::TruncationDimCutoff = DefaultTruncation
	expan::E = DefaultExpansion
end

Base.similar(x::DMRG1S; trunc::TruncationDimCutoff=x.trunc, expan::SubspaceExpansionScheme=x.expan, maxiter::Int=x.maxiter, tol::Float64=x.tol, 
			maxitereig::Int=x.maxitereig, toleig::Float64=x.toleig, verbosity::Int=x.verbosity) = DMRG1S(
			trunc=trunc, expan=x.expan, maxiter=maxiter, tol=tol, maxitereig=maxitereig, toleig=toleig, verbosity=verbosity)


function Base.getproperty(x::DMRG1S, s::Symbol)
	if s == :D
		return x.trunc.D
	elseif s == :ϵ
		return x.trunc.ϵ
	else
		getfield(x, s)
	end
end

function leftsweep!(m::ExpectationCache, alg::DMRG1S)
	mpo = m.mpo
	mps = m.mps
	hstorage = m.env
	trunc = alg.trunc
	Energies = Float64[]
	delta = 0.
	for site in 1:length(mps)-1
		(alg.verbosity > 3) && println("sweeping from left to right at site: $site.")
		# subspace expansion
		right_expansion!(m, site, alg.expan, trunc)
		# end of subspace expansion

		# eigvals, vecs = eigsolve(x->ac_prime(x, mpo[site], hstorage[site], hstorage[site+1]), mps[site], 1, :SR, Lanczos())
		eigvals, vecs = _eig_solver(x->ac_prime(x, mpo[site], hstorage[site], hstorage[site+1]), mps[site], alg.maxitereig, alg.toleig)
		push!(Energies, eigvals)
		(alg.verbosity > 2) && println("Energy after optimization on site $site is $(Energies[end]).")
		# galerkin error
		delta = max(delta, calc_galerkin(m, site) )
		# prepare mps site tensor to be left canonical
		Q, R = leftorth!(vecs, alg=QR())
		mps[site] = Q
		mps[site+1] = @tensor tmp[-1 -2; -3] := R[-1, 1] * mps[site+1][1, -2, -3]
		# hstorage[site+1] = updateleft(hstorage[site], mps[site], mpo[site], mps[site])
		updateleft!(m, site)
	end
	return Energies, delta
end

function rightsweep!(m::ExpectationCache, alg::DMRG1S)
	mpo = m.mpo
	mps = m.mps
	hstorage = m.env
	trunc = alg.trunc
	Energies = Float64[]
	delta = 0.
	for site in length(mps):-1:2
		(alg.verbosity > 3) && println("sweeping from right to left at site: $site.")

		# subspace expansion
		left_expansion!(m, site, alg.expan, trunc)
		# end of subspace expansion

		# eigvals, vecs = eigsolve(x->ac_prime(x, mpo[site], hstorage[site], hstorage[site+1]), mps[site], 1, :SR, Lanczos())
		eigvals, vecs = _eig_solver(x->ac_prime(x, mpo[site], hstorage[site], hstorage[site+1]), mps[site], alg.maxitereig, alg.toleig)
		push!(Energies, eigvals)
		(alg.verbosity > 2) && println("Energy after optimization on site $site is $(Energies[end]).")		
		# galerkin error
		delta = max(delta, calc_galerkin(m, site) )
		# prepare mps site tensor to be right canonical
		L, Q = rightorth(vecs, (1,), (2,3), alg=LQ())
		mps[site] = permute(Q, (1,2), (3,))
		mps[site-1] = @tensor tmp[-1 -2; -3] := mps[site-1][-1, -2, 1] * L[1, -3]
		# hstorage[site] = updateright(hstorage[site+1], mps[site], mpo[site], mps[site])
		updateright!(m, site)
	end
	return Energies, delta
end

"""
	compute!(env::AbstractCache, alg::DMRGAlgorithm)
	execute dmrg iterations
"""
function compute!(env::AbstractCache, alg::DMRGAlgorithm)
	all_energies = Float64[]
	iter = 0
	delta = 2 * alg.tol
	# do a first sweep anyway?
	# Energies, delta = sweep!(env, alg)
	while iter < alg.maxiter && delta > alg.tol
		energy, delta = sweep!(env, alg)
		push!(all_energies, energy)
		iter += 1
		(alg.verbosity > 1) && println("Finish the $iter-th sweep with energy $energy, error $delta", "\n")
	end
	return all_energies, delta
end

"""
	return the ground state
	ground_state!(state::MPS, h::Union{MPOHamiltonian, MPO}, alg::DMRGAlgorithm)
"""
ground_state!(state::MPS, h::Union{MPOHamiltonian, MPO}, alg::DMRGAlgorithm) = compute!(environments(h, state), alg)
ground_state!(state::MPS, h::Union{MPOHamiltonian, MPO}; alg::DMRGAlgorithm=DMRG1S()) = ground_state!(state, h, alg)

get_D(alg::DMRG1) = alg.D
get_D(alg::Union{DMRG2, DMRG1S}) = alg.trunc.D

function ground_state(h::Union{MPOHamiltonian, MPO}, alg::DMRGAlgorithm; kwargs...)
	state = randommps(scalartype(h), physical_spaces(h); D=get_D(alg), kwargs...)
	all_energies, delta = ground_state!(state, h, alg)
	if (alg.verbosity > 0) && (delta > alg.tol)
		@warn "DMRG does not converge (required precision $(alg.tol), actual precision $delta)"
	end
	return all_energies[end], state
end
