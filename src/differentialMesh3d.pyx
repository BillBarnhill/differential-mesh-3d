# -*- coding: utf-8 -*-
# cython: profile=True

from __future__ import division

cimport cython
cimport mesh3d

from zonemap3d cimport Zonemap3d

from cython.parallel import parallel, prange

from libc.math cimport sqrt
from libc.math cimport cos
from libc.math cimport sin
from libc.math cimport fabs

from helpers cimport double_array_init
from helpers cimport int_array_init
from helpers cimport vcross

import numpy as np
cimport numpy as np

cdef int procs = 4

cdef class DifferentialMesh3d(mesh3d.Mesh3d):

  def __init__(self, int nmax, double zonewidth, double nearl, double farl):

    mesh3d.Mesh3d.__init__(self, nmax, zonewidth)

    """
    - nearl is the closest comfortable distance between two vertices.

    - farl is the distance beyond which disconnected vertices will ignore
    each other
    """

    self.nearl = nearl

    self.farl = farl

    self.num_sources = 0

    self.source_zonemap = Zonemap3d(self.nz)
    self.source_zonemap.__assign_xyz_arrays(self.SX, self.SY, self.SZ)

    print('nearl: {:f}'.format(nearl))
    print('farl: {:f}'.format(farl))

    return

  def __cinit__(self, int nmax, *arg, **args):

    self.DX = <double *>malloc(nmax*sizeof(double))

    self.DY = <double *>malloc(nmax*sizeof(double))

    self.DZ = <double *>malloc(nmax*sizeof(double))

    self.SX = <double *>malloc(nmax*sizeof(double))

    self.SY = <double *>malloc(nmax*sizeof(double))

    self.SZ = <double *>malloc(nmax*sizeof(double))

    return

  def __dealloc__(self):

    free(self.DX)

    free(self.DY)

    free(self.DZ)

    free(self.SX)

    free(self.SY)

    free(self.SZ)

    return

  @cython.wraparound(False)
  @cython.boundscheck(False)
  @cython.nonecheck(False)
  cdef int __find_nearby_sources(self) nogil:

    cdef int v
    cdef int n
    cdef int num
    cdef int hits = 0

    cdef int asize = self.source_zonemap.__get_max_sphere_count()
    cdef int *vertices = <int *>malloc(asize*sizeof(int))

    for v in xrange(self.vnum):

      num = self.source_zonemap.__sphere_vertices(
        self.X[v],
        self.Y[v],
        self.Z[v],
        self.source_rad,
        vertices
      )

      for n in xrange(num):

        self.source_zonemap.__del_vertex(vertices[n])
        self.__set_vertex_intensity(v, 1.0)

        hits += 1

    free(vertices)

    return hits

  @cython.wraparound(False)
  @cython.boundscheck(False)
  @cython.nonecheck(False)
  cdef int __smooth_intensity(self) nogil:

    cdef int e
    cdef int v1
    cdef int v2
    cdef double newi

    for e in xrange(self.henum):

      v1 = self.HE[e].first
      v2 = self.HE[e].last

      newi = (self.I[v1] + self.I[v2]) * 0.5

      self.I[v1] = newi
      self.I[v2] = newi

    return 1

  @cython.wraparound(False)
  @cython.boundscheck(False)
  @cython.nonecheck(False)
  @cython.cdivision(True)
  cdef int __reject(self, double scale) nogil:
    """
    all vertices will move away from all neighboring (closer than farl)
    vertices
    """

    cdef double farl = self.farl
    cdef double nearl = self.nearl

    cdef int v
    cdef int k
    cdef int neigh

    cdef double x
    cdef double y
    cdef double z
    cdef double dx
    cdef double dy
    cdef double dz
    cdef double nrm
    cdef double s

    cdef double resx = 0.
    cdef double resy = 0.
    cdef double resz = 0.

    cdef int asize = self.zonemap.__get_max_sphere_count()
    cdef int *vertices
    cdef int neighbor_num

    with nogil, parallel(num_threads=procs):

      vertices = <int *>malloc(asize*sizeof(int))
      for v in prange(self.vnum, schedule='guided'):

        x = self.X[v]
        y = self.Y[v]
        z = self.Z[v]
        neighbor_num = self.zonemap.__sphere_vertices(x, y, z, farl, vertices)

        resx = 0.
        resy = 0.
        resz = 0.
        for k in range(neighbor_num):

          neigh = vertices[k]
          if neigh == v:
            continue

          dx = x-self.X[neigh]
          dy = y-self.Y[neigh]
          dz = z-self.Z[neigh]
          nrm = sqrt(dx*dx+dy*dy+dz*dz)

          if nrm>farl or nrm<=0.0:
            continue

          dx = dx/nrm
          dy = dy/nrm
          dz = dz/nrm

          s = farl-nrm

          #if nrm<nearl:
            #s *= 2.0

          resx += dx*s
          resy += dy*s
          resz += dz*s

        self.DX[v] += resx
        self.DY[v] += resy
        self.DZ[v] += resz

      free(vertices)

    return 1


  @cython.wraparound(False)
  @cython.boundscheck(False)
  @cython.nonecheck(False)
  @cython.cdivision(True)
  cdef int __attract(self, double scale) nogil:
    """
    vertices will move towards all connected vertices further away than
    nearl
    """

    cdef int v1
    cdef int v2
    cdef int k

    cdef double nearl = self.nearl

    cdef double dx
    cdef double dy
    cdef double dz
    cdef double nrm

    cdef double s

    for k in xrange(self.henum):

      v1 = self.HE[k].first
      v2 = self.HE[k].last

      dx = self.X[v2]-self.X[v1]
      dy = self.Y[v2]-self.Y[v1]
      dz = self.Z[v2]-self.Z[v1]
      nrm = sqrt(dx*dx+dy*dy+dz*dz)

      if nrm<0.:
        continue

      if self.HE[k].twin>-1:

        # internal edge. has two opposing half edges
        # half the force because it is applied twice
        s = scale*0.5/nrm

        if nrm>nearl:

          ## attract
          self.DX[v1] += dx*s
          self.DY[v1] += dy*s
          self.DZ[v1] += dz*s

        elif nrm<=nearl:

          ## reject
          self.DX[v1] -= dx*s
          self.DY[v1] -= dy*s
          self.DZ[v1] -= dz*s

      else:

        # surface edge has one half edge, and they are all rotated the same way
        s = scale/nrm

        if nrm>nearl:

          ## attract
          self.DX[v1] += dx*s
          self.DY[v1] += dy*s
          self.DZ[v1] += dz*s
          # and the other vertex
          self.DX[v2] -= dx*s
          self.DY[v2] -= dy*s
          self.DZ[v2] -= dz*s

        elif nrm<=nearl:

          ## reject
          self.DX[v1] -= dx*s
          self.DY[v1] -= dy*s
          self.DZ[v1] -= dz*s
          # and the other vertex
          self.DX[v2] += dx*s
          self.DY[v2] += dy*s
          self.DZ[v2] += dz*s

    return 1

  @cython.wraparound(False)
  @cython.boundscheck(False)
  @cython.nonecheck(False)
  @cython.cdivision(True)
  cdef int __unfold(self, double scale) nogil:
    """
    """

    cdef int v1
    cdef int v2
    cdef int first
    cdef int last
    cdef int k

    cdef double dx
    cdef double dy
    cdef double dz
    cdef double midx
    cdef double midy
    cdef double midz
    cdef double v1x
    cdef double v1y
    cdef double v1z
    cdef double v2x
    cdef double v2y
    cdef double v2z

    cdef double dv1x
    cdef double dv1y
    cdef double dv1z
    cdef double dv2x
    cdef double dv2y
    cdef double dv2z

    cdef double dnrmv1
    cdef double dnrmv2

    cdef double nrm
    cdef double invdot

    cdef double s

    for k in xrange(self.henum):

      if self.__is_surface_edge(k)<0:
        continue

      first = self.HE[k].first
      last = self.HE[k].last

      midx = (self.X[first] + self.X[last])*0.5
      midy = (self.Y[first] + self.Y[last])*0.5
      midz = (self.Z[first] + self.Z[last])*0.5

      v1 = self.HE[self.HE[k].next].last
      v2 = self.HE[self.HE[self.HE[k].twin].next].last

      v1x = self.X[v1]
      v1y = self.Y[v1]
      v1z = self.Z[v1]
      v2x = self.X[v2]
      v2y = self.Y[v2]
      v2z = self.Z[v2]

      dv1x = v1x - midx
      dv1y = v1y - midy
      dv1z = v1z - midz
      dv2x = v2x - midx
      dv2y = v2y - midy
      dv2z = v2z - midz

      dx = v2x-v1x
      dy = v2y-v1y
      dz = v2z-v1z
      nrm = sqrt(dx*dx+dy*dy+dz*dz)

      if nrm<=0:
        continue

      dnrmv1 = sqrt(dv1x*dv1x+dv1y*dv1y+dv1z*dv1z)
      dnrmv2 = sqrt(dv2x*dv2x+dv2y*dv2y+dv2z*dv2z)

      if dnrmv1<=0.0 or dnrmv2<=0.0:
        continue

      invdot = 1.0 - fabs(
        dv1x/dnrmv1*dv2x/dnrmv2+
        dv1y/dnrmv1*dv2y/dnrmv2+
        dv1z/dnrmv1*dv2z/dnrmv2
      )

      s = scale/nrm*invdot

      ## reject
      self.DX[v1] -= dx*s
      self.DY[v1] -= dy*s
      self.DZ[v1] -= dz*s

    return 1

  @cython.wraparound(False)
  @cython.boundscheck(False)
  @cython.nonecheck(False)
  @cython.cdivision(True)
  cdef int __edge_vertex_force(self, int he1, int v1, double scale) nogil:

    cdef int henum = self.henum
    cdef double nearl = self.nearl

    cdef int a = self.HE[he1].first
    cdef int b = self.HE[he1].last

    cdef double x = (self.X[b]+self.X[a])*0.5
    cdef double y = (self.Y[b]+self.Y[a])*0.5
    cdef double z = (self.Z[b]+self.Z[a])*0.5

    cdef double dx = self.X[v1]-x
    cdef double dy = self.Y[v1]-y
    cdef double dz = self.Z[v1]-z

    cdef double nrm = sqrt(dx*dx+dy*dy+dz*dz)

    if nrm<=0:

      return -1

    if nrm>0.5*sqrt(3.0)*nearl:

      #pass
      self.DX[v1] += -dx/nrm*scale
      self.DY[v1] += -dy/nrm*scale

    else:

      self.DX[v1] += dx/nrm*scale
      self.DY[v1] += dy/nrm*scale

    return 1

  @cython.wraparound(False)
  @cython.boundscheck(False)
  @cython.nonecheck(False)
  cdef int __triangle_force(self, double scale) nogil:

    cdef int ab
    cdef int bc
    cdef int ca

    for f in xrange(self.fnum):

      ab = self.FHE[f]
      bc = self.HE[ab].next
      ca = self.HE[bc].next

      self.__edge_vertex_force(ab,self.HE[ca].first,scale)
      self.__edge_vertex_force(bc,self.HE[ab].first,scale)
      self.__edge_vertex_force(ca,self.HE[ab].last,scale)

    return 1

  @cython.wraparound(False)
  @cython.boundscheck(False)
  @cython.nonecheck(False)
  cpdef int optimize_position(self, double step, int itt, int scale_intensity):

    cdef int v
    cdef int i
    cdef int free

    cdef double reject_scale = 1.0
    cdef double scale = 0.1
    cdef double intensity = 1.0

    cdef double s = step
    cdef double x
    cdef double y
    cdef double z

    for i in xrange(itt):

      double_array_init(self.DX, self.vnum, 0.)
      double_array_init(self.DY, self.vnum, 0.)
      double_array_init(self.DZ, self.vnum, 0.)

      self.__reject(reject_scale)
      self.__attract(scale)
      self.__unfold(scale)

      for v in xrange(self.vnum):

        if scale_intensity>0:
          s = step*self.I[v]

        x = self.X[v] + s*self.DX[v]
        y = self.Y[v] + s*self.DY[v]
        z = self.Z[v] + s*self.DZ[v]
        free = self.zonemap.__sphere_is_free_ignore(x, y, z, v, self.nearl*0.3)
        if free<0:
          print('block', v)
          continue

        self.X[v] = x
        self.Y[v] = y
        self.Z[v] = z

    return 1

  @cython.wraparound(False)
  @cython.boundscheck(False)
  @cython.nonecheck(False)
  cpdef int position_noise(self, np.ndarray[double, mode="c",ndim=2] a, int scale_intensity):

    cdef int v
    cdef double intensity = 1

    for v in xrange(self.vnum):

      if scale_intensity>0:
        intensity = self.I[v]

      self.X[v] += a[v,0]*intensity
      self.Y[v] += a[v,1]*intensity
      self.Z[v] += a[v,2]*intensity

    return 1

  @cython.wraparound(False)
  @cython.boundscheck(False)
  @cython.nonecheck(False)
  cpdef int initialize_sources(self, list sources, double source_rad):

    cdef int i
    cdef int num_sources
    cdef double x
    cdef double y

    num_sources = len(sources)
    self.num_sources = num_sources
    self.source_rad = source_rad

    for i in xrange(num_sources):

      x,y,z = sources[i]
      self.SX[i] = x
      self.SY[i] = y
      self.SZ[i] = z

      self.source_zonemap.__add_vertex(i)

    print('initialized sources: {:d}'.format(num_sources))

    return 1

  @cython.wraparound(False)
  @cython.boundscheck(False)
  @cython.nonecheck(False)
  cpdef int find_nearby_sources(self):

    return self.__find_nearby_sources()

  @cython.wraparound(False)
  @cython.boundscheck(False)
  @cython.nonecheck(False)
  cpdef int smooth_intensity(self):

    return self.__smooth_intensity()

