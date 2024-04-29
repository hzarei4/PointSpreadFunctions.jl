using PointSpreadFunctions
using Zygote



Zygote.forwarddiff(psf((256, 256, 256), PSFParams; sampling=sampling), (0.488, 1.4, 1.52))

k(x) = psf((256, 256, 256), PSFParams(x); sampling=(0.050,0.050,0.050));


k((0.488, 1.4, 1.52))



l(x) = PSFParams(x)


