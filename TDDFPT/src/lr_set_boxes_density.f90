!-----------------------------------------------------------------------
!OBM
! 150608 pfft replaced by fft_base :: dfftp
SUBROUTINE lr_set_boxes_density() 
  !---------------------------------------------------------------------
  ! ... set boxes for the calculation of density response
  !---------------------------------------------------------------------
  !
  ! Modified by Osman Baris Malcioglu (2009)
#include "f_defs.h"
  !
  use io_global,            only : stdout
  use kinds,                only : dp
  use lr_variables,         only : cube_save 
  !use pfft,                 only : npp
  use fft_base,              only : dfftp
  use mp_global,            only : me_pool
  USE lr_variables,   ONLY : lr_verbosity
  !
  IMPLICIT NONE
  !
  INTEGER :: index0, index, ir
  INTEGER :: i, j, k, p, nr
  !
  If (lr_verbosity > 5) THEN
    WRITE(stdout,'("<lr_set_boxes_density>")')
  endif
  CALL start_clock( 'lr_set_boxes' )
  !
  ALLOCATE( cube_save( dfftp%nnr, 3 ) )
  cube_save = 0
  !
  index0 = 0
  !
#if defined (__PARA)
  !
  DO i = 1, me_pool
     index0 = index0 + dfftp%nr1x*dfftp%nr2x*dfftp%npp(i)
  END DO
  !
#endif
  !
  DO ir = 1, dfftp%nnr
     !
     ! ... three dimensional indexes
     !
     index = index0 + ir - 1
     k     = index / (dfftp%nr1x*dfftp%nr2x)
     index = index - (dfftp%nr1x*dfftp%nr2x)*k
     j     = index / dfftp%nr1x
     index = index - dfftp%nr1x*j
     i     = index
     !
     IF ( i.GE.dfftp%nr1 .OR. j.GE.dfftp%nr2 .OR. k.GE.dfftp%nr3 ) CYCLE
     !
     cube_save(ir,1) = i
     cube_save(ir,2) = j
     cube_save(ir,3) = k
     !
  END DO
  !
  CALL stop_clock( 'lr_set_boxes' )
  !
  END SUBROUTINE lr_set_boxes_density
