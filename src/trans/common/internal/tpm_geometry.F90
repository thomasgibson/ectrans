! (C) Copyright 2000- ECMWF.
! (C) Copyright 2000- Meteo-France.
! 
! This software is licensed under the terms of the Apache Licence Version 2.0
! which can be obtained at http://www.apache.org/licenses/LICENSE-2.0.
! In applying this licence, ECMWF does not waive the privileges and immunities
! granted to it by virtue of its status as an intergovernmental organisation
! nor does it submit to any jurisdiction.
!

MODULE TPM_GEOMETRY

! Module containing data describing Gaussian grid.

USE EC_PARKIND  ,ONLY : JPIM     ,JPRD

IMPLICIT NONE

SAVE

TYPE GEOM_TYPE
INTEGER(KIND=JPIM),ALLOCATABLE :: NLOEN(:) ! NUMBER OF POINTS ON A PARALLEL
INTEGER(KIND=JPIM),ALLOCATABLE :: NMEN(:)  ! ASSOCIATED CUT-OFF WAVE NUMBER
INTEGER(KIND=JPIM),ALLOCATABLE :: NDGLU(:) ! NUMBER OF HEMISPERIC LATITUDES
!                                   FOR A GIVEN WAVE NUMBER M 

LOGICAL :: LAM           ! LAM geometry if T, Global geometry if F
LOGICAL :: LREDUCED_GRID ! Reduced Gaussian grid if T
!                          quadratic Gaussian grid otherwise.
REAL(KIND=JPRD) :: RSTRET ! Stretching factor (for Legendre polynomials
!                           computed on stretched latitudes only)
END TYPE GEOM_TYPE

TYPE(GEOM_TYPE),ALLOCATABLE,TARGET :: GEOM_RESOL(:)
TYPE(GEOM_TYPE),POINTER     :: G

!flat copies of the above
INTEGER(KIND=JPIM),ALLOCATABLE :: G_NDGLU(:) ! NUMBER OF HEMISPERIC LATITUDES
INTEGER(KIND=JPIM),ALLOCATABLE :: G_NMEN(:)  ! ASSOCIATED CUT-OFF WAVE NUMBER
INTEGER(KIND=JPIM) :: G_NMEN_MAX
INTEGER(KIND=JPIM),ALLOCATABLE :: G_NLOEN(:) ! NUMBER OF POINTS ON A PARALLEL
INTEGER(KIND=JPIM) :: G_NLOEN_MAX

END MODULE TPM_GEOMETRY
