"""
    amp_to_int(field) 

converts a complex-valued amplitude field to intensity via `abs2.` and summing over the 4th dimension.
"""
amp_to_int(field) = sum(abs2.(field), dims=4)

"""
    has_z_symmetry(pp::PSFParams)

checks whether the point spread function is expected to be symmetric along the z-direction. Currently this is defined by the aberration list being empty.
"""
function has_z_symmetry(pp::PSFParams)
    return isnothing(pp.aberrations) || isempty(pp.aberrations.indices); # will be changed later, when assymetric aberrations are allowed
end

"""
    get_Abbe_limit(pp::PSFParams)

returns the Abbe limit of incoherent imaging in real space as a Tuple with 3 entries. Note that the coherent limit needs only a factor of
two less sampling, as long as no intensity is calculated. This allows upsampling right before calculating intensities.

See also:
+ get_required_amp_sampling()

Example:
```jdoctest
julia> using PSFs

julia> pp = PSFParams(580.0, 1.4, 1.518)
PSFParams(580.0, 1.4, 1.518, Float32, ModeWidefield, PSFs.pol_scalar, PSFs.var"#42#43"(), PSFs.MethodPropagateIterative, nothing, Aberrations(Any[], Any[], :OSA), nothing)

julia> PSFs.get_Abbe_limit(pp)
(191.04085f0, 191.04085f0, 234.38591f0)
```
"""
function get_Abbe_limit(pp::PSFParams)
    d_xy = pp.λ ./ (2 .* pp.n) 
    d_z = (1 - cos(asin(pp.NA/ pp.n))) * pp.λ / pp.n
    pp.dtype.((d_xy,d_xy,d_z))
end

"""
    get_required_amp_sampling(sz::NTuple, pp::PSFParams)

returns the necessary sampling (in real space) for sampling amplitudes. This is almost corresponding to the Abbe limit. Factor of two less because of amplitude but twice because of the Nyquist theorem. 
However, this is slight modified by requiring slightly higher sampling (one empty pixel on each side of Fourier space) to stay clear of ambiguities.

See also:
+ get_Abbe_limit()

Example:
```jdoctest
julia> using PSFs

julia> pp = PSFParams(580.0, 1.4, 1.518)
PSFParams(580.0, 1.4, 1.518, Float32, ModeWidefield, PSFs.pol_scalar, PSFs.var"#42#43"(), PSFs.MethodPropagateIterative, nothing, Aberrations(Any[], Any[], :OSA), nothing)

julia> sz = (256,256,64)
(256, 256, 64)

julia> PSFs.get_required_amp_sampling(sz,pp)
(188.05583f0, 188.05583f0, 219.73679f0)

```
"""
function get_required_amp_sampling(sz::NTuple, pp::PSFParams)
    abbe = get_Abbe_limit(pp)[1:length(sz)]
    sz2 = sz .÷ 2
    abbe .* (sz2.-2) ./ sz2 # provide a minimum amount of oversampling to avoid problems with the border pixesl.
end

"""
    get_Ewald_sampling(sz::NTuple, pp::PSFParams)

returns the required minimum sampling for the calculation of a full Ewald sphere.
"""
function get_Ewald_sampling(sz::NTuple, pp::PSFParams)
    s_xyz = pp.λ ./ (2 .* pp.n) 
    sz2 = sz .÷ 2
    s_xyz .* (sz2.-2) ./ sz2 # provide a minimum amount of oversampling to avoid problems with the border pixesl.
end


"""
    get_McCutchen_kz_center(ft_shell, pp::PSFParams, sampling)

calculates the (rounded) pixels position half way between both, the kz-borders of the McCutchen pupil to extract from the full sized Ewald sphere.
The pixel z position is returned together with the corresponding kz position.
"""
function get_McCutchen_kz_center(sz, pp::PSFParams, sampling)
    k_z_scale = k_scale(sz, pp, sampling)[3]
    dkz = k_dz(pp) ./ k_z_scale
    pk0 = k_0(pp) ./ k_z_scale
    old_center = sz .÷ 2 .+ 1
    new_center = (old_center[1], old_center[2], round(eltype(old_center), old_center[3] .+ pk0 .- dkz /2))
    # kz_center = (new_center[3] - old_center[3]) * k_z_scale
    return new_center, new_center[3]-old_center[3]
end

"""
    limit_k_z(ft_shell, pp::PSFParams, sampling)

limits the k_z range of the ewald-sphere.
returns the extracted region and the new sampling
"""
function limit_kz(ft_shell, pp::PSFParams, sampling)
    sz = size(ft_shell)
    get_kz_center(sz, pp, sampling)
    dkz = k_dz(pp) ./ k_z_scale
    new_size = (sz[1], sz[2], ceil(eltype(sz), dkz).+1) 
    cut_shell = FourierTools.select_region_ft(ft_shell, center = new_center, new_size = new_size)
    sampling = (sampling[1],sampling[2],sampling[2] * sz[3] / new_size[3])
    return cut_shell, sampling 
end

"""
    sinc_r(sz::NTuple, pp::PSFParams; sampling=nothing)

calculates the 3-dimensional `sinc(abs(position))` scaled such that the Fourier transformation yields the k-sphere.
Note that for this to work the sampling needs to be sufficient, which may be problematic especially along the z-direction.
This can be checked with the help of the `get_Ewald_sampling()` function.

See also:
+ get_Ewald_sampling()
+ jinc_r_2d

"""
function sinc_r(sz::NTuple, pp::PSFParams; sampling=nothing)
    if isnothing(sampling)
        sampling=get_Ewald_sampling(sz, pp)
    end 
    sinc.(rr(pp.dtype, sz, scale=2 .*sampling ./ (pp.λ./pp.n)))
end

"""
    jinc_r_2d(sz::NTuple, pp::PSFParams; sampling=nothing)

calculates a jinc(abs(position)) function in 2D such that its Fourier transform corresponds to the disk-shaped pupil (indcluding the effect ot the numerical aperture).

See also:
+ sinc_r()

"""
function jinc_r_2d(sz::NTuple, pp::PSFParams; sampling=nothing)
    if isnothing(sampling)
        sampling=get_Ewald_sampling(sz, pp)
    end 
    jinc.(rr(pp.dtype, sz[1:2], scale=2 .*sampling[1:2] ./ (pp.λ./pp.NA)))
end

# my_disc(sz; rel_border=4/3, eps=0.05) = window_hanning(sz, border_in=rel_border.-eps, border_out=rel_border.+eps)
"""
    my_disc(sz, pp) 

creates a disc such that there is no overalp upon wrap-around, when convolving it with itself on this grid.
This is the radius where there is no overlap. However, in the cornes of the calculation, the results are not
100% accurate as something is missing.
"""
my_disc(sz, pp) = disc(pp.dtype, sz, sz .* (1/3))  # This is the radius where there is no overlap and the diagonals (sqrt(2)) are still covered
# my_disc(sz, pp) = disc(pp.dtype, sz, sz .* (sqrt(2)/3))  # This is the radius where there is no overlap and the diagonals (sqrt(2)) are still covered

"""
    iftz(arr)

inverse Fourier transform only along the 3rd dimension (kz).

Arguments:
+ arr:  array to transform along kz
"""
iftz(arr) = ift(arr,(3,))

"""
    theta_z(sz)

a θ function along the z direction, being one for z positon > 0 and zero elsewhere.

Arguments:
+ sz:  size of the array
"""
theta_z(sz) = (zz((1,1,sz[3])) .> 0) # The direction is important due to the highest frequency position at even-sized FFTs



"""
    k_0(pp::PSFParams)

k in the medium as n/lambda.   (1/space units

Arguments:
+ `pp`:  PSF parameter structure
""" 
function k_0(pp::PSFParams)
    pp.dtype(pp.n / pp.λ)
end

"""
    k_pupil(pp::PSFParams)

maxim radial k-coordinate (1/space units) where the pupil ends

Arguments:
+ `pp`:  PSF parameter structure
"""
function k_pupil(pp::PSFParams)
    pp.dtype(pp.NA / pp.λ)
end

"""
    k_dz(pp::PSFParams)

relative kz range from pupil boarder to top of Ewald sphere

Arguments:
+ `pp`:  PSF parameter structure
"""
function k_dz(pp::PSFParams)
    pp.dtype((1 - cos(asin(pp.NA/ pp.n))) * k_0(pp))
end

"""
    k_scale(sz,pp,sampling)
    pixelpitch (as NTuple) in k-space
+ `sz`:  size of the real-space array
+ `pp`:  PSF parameter structure
+ `sampling`: pixelpitch in real space as NTuple
"""
function k_scale(sz, pp::PSFParams, sampling)
    pp.dtype.(1 ./ (sz .* sampling))
end

"""
    k_pupil_pos(sz, pp::PSFParams, sampling)

returns the X and Y position of the pupil border in reciprocal space pixels.

Arguments:
+ `sz`:  size of the real-space array
+ `pp`:  PSF parameter structure
+ `sampling`: pixelpitch in real space as NTuple
"""
function k_pupil_pos(sz, pp::PSFParams, sampling)
    k_pupil(pp) ./ k_scale(sz, pp, sampling)
end

"""
    k_0_pos(sz, pp::PSFParams, sampling)

returns the X and Y position of the Ewald-sphere border in reciprocal space pixels.

Arguments:
+ `sz`:  size of the real-space array
+ `pp`:  PSF parameter structure
+ `sampling`: pixelpitch in real space as NTuple
"""
function k_0_pos(sz, pp::PSFParams, sampling)
    k_0(pp) ./ k_scale(sz, pp, sampling)
end

"""
    k_r(sz, pp::PSFParams, sampling)

returns an array of radial k coordinates, |k_xy|
"""
function k_r(sz, pp::PSFParams, sampling)
    min.(k_0(pp), rr(pp.dtype, sz[1:2],scale = k_scale(sz[1:2], pp, sampling[1:2])))
end

"""
    k_xy(sz,pp,sampling)

yields a 2D array with each entry being a 2D Tuple.
"""
function k_xy(sz,pp,sampling)
    idx(pp.dtype, sz[1:2],scale = k_scale(sz[1:2], pp, sampling[1:2]))
end

"""
    k_xy_rel_pupil(sz,pp,sampling)

returns an array of relative distance to the pupil border
"""
function k_xy_rel_pupil(sz,pp,sampling)
    idx(pp.dtype, sz[1:2],scale = k_scale(sz[1:2], pp, sampling[1:2]) ./ k_pupil(pp))
end

"""
    check_amp_sampling_xy(sz, pp,sampling)

issues a warning if the amplitude sampling along X and Y is not within the required limits.

See also:
+ get_Abbe_limit()
+ get_required_amp_sampling()
+ check_amp_sampling()
+ check_amp_sampling_z()

Arguments:
+ `sz`:  size of the real-space array
+ `pp`:  PSF parameter structure
+ `sampling`: pixelpitch in real space as NTuple
"""
function check_amp_sampling_xy(sz, pp,sampling)
    sample_factor = k_pupil(pp) ./ ((sz[1:2] .÷2) .* k_scale(sz, pp, sampling)[1:2])
    if any(sample_factor .> 1.0)
        @warn "Your calculation is undersampled along XY by factors of $sample_factor. The PSF calculation will be incorrect.)"
    end
end

"""
    check_amp_sampling_z(sz, pp,sampling)

issues a warning if the amplitude sampling along Z is not within the required limits.

See also:
+ get_Abbe_limit()
+ get_required_amp_sampling()
+ check_amp_sampling_xy()
+ check_amp_sampling()

Arguments:
+ `sz`:  size of the real-space array
+ `pp`:  PSF parameter structure
+ `sampling`: pixelpitch in real space as NTuple
"""
function check_amp_sampling_z(sz, pp,sampling)
    sample_factor = k_dz(pp) ./ ((sz[3] .÷2) .* k_scale(sz, pp, sampling)[3])
    if (sample_factor > 1.0)
        @warn "Your calculation is undersampled along Z by factors of $sample_factor. The PSF calculation will be incorrect.)"
    end
end

"""
    check_amp_sampling(sz, pp,sampling)

issues a warning if the amplitude sampling (X,Y and Z) is not within the required limits.

See also:
+ get_Abbe_limit()
+ get_required_amp_sampling()
+ check_amp_sampling_xy()
+ check_amp_sampling_z()

Arguments:
+ `sz`:  size of the real-space array
+ `pp`:  PSF parameter structure
+ `sampling`: pixelpitch in real space as NTuple
"""
function check_amp_sampling(sz, pp,sampling)
    check_amp_sampling_xy(sz, pp, sampling)
    check_amp_sampling_z(sz, pp, sampling)
end

"""
    check_amp_sampling_sincr(sz, pp,sampling)

issues a warning if the amplitude sampling (X,Y and Z) is not within the required limits for the `SincR` method, as this requires sampling
the Ewald-sphere according to Nyquist.

See also:
+ get_Abbe_limit()
+ get_required_amp_sampling()
+ check_amp_sampling()
+ get_Ewald_sampling()

Arguments:
+ `sz`:  size of the real-space array
+ `pp`:  PSF parameter structure
+ `sampling`: pixelpitch in real space as NTuple
"""
function check_amp_sampling_sincr(sz, pp,sampling) # The sinc-r method needs (for now without aliasing) to be sampled extremely high along Z
    check_amp_sampling_xy(sz, pp, sampling)
    @show sample_factor = k_0(pp) ./ ((sz[3] .÷2) .* k_scale(sz, pp, sampling)[3])
    if (sample_factor > 1.0)
        @warn "Your calculation is undersampled along Z by factors of $sample_factor. The PSF calculation will be incorrect.)"
    end
end

