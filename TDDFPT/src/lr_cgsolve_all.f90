!
! Copyright (C) 2001-2004 PWSCF group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!



#include "f_defs.h"
!
!----------------------------------------------------------------------
subroutine lr_cgsolve_all (h_psi, cg_psi, e, d0psi, dpsi, h_diag, &
     ndmx, ndim, ethr, ik, kter, conv_root, anorm, nbnd, npol)
  !----------------------------------------------------------------------
  ! Modified by Osman Baris Malcioglu in 2009 
  !
  !     iterative solution of the linear system:
  !
  !                 ( h - e + Q ) * dpsi = d0psi                      (1)
  !
  !                 where h is a complex hermitean matrix, e is a real sca
  !                 dpsi and d0psi are complex vectors
  !
  !     on input:
  !                 h_psi    EXTERNAL  name of a subroutine:
  !                          h_psi(ndim,psi,psip)
  !                          Calculates  H*psi products.
  !                          Vectors psi and psip should be dimensined
  !                          (ndmx,nvec). nvec=1 is used!
  !
  !                 cg_psi   EXTERNAL  name of a subroutine:
  !                          g_psi(ndmx,ndim,notcnv,psi,e)
  !                          which calculates (h-e)^-1 * psi, with
  !                          some approximation, e.g. (diag(h)-e)
  !
  !                 e        real     unperturbed eigenvalue.
  !
  !                 dpsi     contains an estimate of the solution
  !                          vector.
  !
  !                 d0psi    contains the right hand side vector
  !                          of the system.
  !
  !                 ndmx     integer row dimension of dpsi, ecc.
  !
  !                 ndim     integer actual row dimension of dpsi
  !
  !                 ethr     real     convergence threshold. solution
  !                          improvement is stopped when the error in
  !                          eq (1), defined as l.h.s. - r.h.s., becomes
  !                          less than ethr in norm.
  !
  !     on output:  dpsi     contains the refined estimate of the
  !                          solution vector.
  !
  !                 d0psi    is corrupted on exit
  !
  !   revised (extensively)       6 Apr 1997 by A. Dal Corso & F. Mauri
  !   revised (to reduce memory) 29 May 2004 by S. de Gironcoli
  !
  USE kinds, only : DP
  USE mp_global, ONLY: intra_pool_comm
  USE mp,        ONLY: mp_sum
  USE control_flags,     ONLY: gamma_only
  USE io_global,  ONLY: stdout
  USE lr_variables,  ONLY: lr_verbosity
  USE gvect,     ONLY: gstart

  implicit none
  !
  !   first the I/O variables
  !
  integer :: ndmx, & ! input: the maximum dimension of the vectors
             ndim, & ! input: the actual dimension of the vectors
             kter, & ! output: counter on iterations
             nbnd, & ! input: the number of bands
             npol, & ! input: number of components of the wavefunctions
             ik      ! input: the k point

  real(DP) :: &
             e(nbnd), & ! input: the actual eigenvalue
             anorm,   & ! output: the norm of the error in the solution
             h_diag(ndmx*npol,nbnd), & ! input: an estimate of ( H - \epsilon )
             ethr       ! input: the required precision

  complex(DP) :: &
             dpsi (ndmx*npol, nbnd), & ! output: the solution of the linear syst
             d0psi (ndmx*npol, nbnd)   ! input: the known term

  logical :: conv_root ! output: if true the root is converged
  external h_psi, &    ! input: the routine computing h_psi
           cg_psi      ! input: the routine computing cg_psi
  !
  !  here the local variables
  !
  integer, parameter :: maxter = 200
  ! the maximum number of iterations
  integer :: iter, ibnd, lbnd
  ! counters on iteration, bands
  integer , allocatable :: conv (:)
  ! if 1 the root is converged

  complex(DP), allocatable :: g (:,:), t (:,:), h (:,:), hold (:,:)
  !  the gradient of psi
  !  the preconditioned gradient
  !  the delta gradient
  !  the conjugate gradient
  !  work space
  complex(DP) ::  dcgamma, dclambda
  !  the ratio between rho
  !  step length
  complex(DP), external :: zdotc
  real(kind=dp), external :: ddot
  !  the scalar product
  real(DP), allocatable :: rho (:), rhoold (:), eu (:), a(:), c(:)
  ! the residue
  ! auxiliary for h_diag
  real(DP) :: kter_eff
  ! account the number of iterations with b
  ! coefficient of quadratic form
  !
  !obm debug
  !real(DP) :: obm_debug
  call start_clock ('cgsolve')
  
  If (lr_verbosity > 5) WRITE(stdout,'("<lr_cgsolve_all>")')
  
  !OBM debug
  !      obm_debug=0
  !     do ibnd=1,nbnd
  !        !
  !        obm_debug=obm_debug+ZDOTC(ndim,d0psi(:,ibnd),1,d0psi(:,ibnd),1)
  !        !
  !     enddo
  !     print *, "cq_solve_all initial d0psi", obm_debug
  !
  !!obm_debug

  allocate ( g(ndmx*npol,nbnd), t(ndmx*npol,nbnd), h(ndmx*npol,nbnd), &
             hold(ndmx*npol ,nbnd) )    
  allocate (a(nbnd), c(nbnd))    
  allocate (conv ( nbnd))    
  allocate (rho(nbnd),rhoold(nbnd))    
  allocate (eu (  nbnd))    
  !      WRITE( stdout,*) g,t,h,hold

  kter_eff = 0.d0
  do ibnd = 1, nbnd
     conv (ibnd) = 0
  enddo
  g=(0.d0,0.d0)
  t=(0.d0,0.d0)
  h=(0.d0,0.d0)
  hold=(0.d0,0.d0)
  do iter = 1, maxter
     !
     !    compute the gradient. can reuse information from previous step
     !
     if (iter == 1) then
        call h_psi (ndim, dpsi, g, e, ik, nbnd)
        do ibnd = 1, nbnd
           call zaxpy (ndim, (-1.d0,0.d0), d0psi(1,ibnd), 1, g(1,ibnd), 1)
        enddo
        IF (npol==2) THEN
           do ibnd = 1, nbnd
              call zaxpy (ndim, (-1.d0,0.d0), d0psi(ndmx+1,ibnd), 1, &
                                              g(ndmx+1,ibnd), 1)
           enddo
        END IF
       !print *, "first iteration"
     endif
     !OBM debug
     !  obm_debug=0
     !  do ibnd=1,nbnd
     !     !
     !     obm_debug=obm_debug+ZDOTC(ndim,dpsi(:,ibnd),1,dpsi(:,ibnd),1)
     !     !
     !  enddo
     !  print *, "cq_solve_all dpsi", obm_debug 
     !  obm_debug=0
     !  do ibnd=1,nbnd
     !     !
     !     obm_debug=obm_debug+ZDOTC(ndim,d0psi(:,ibnd),1,d0psi(:,ibnd),1)
     !     !
     !  enddo
     !  print *, "cq_solve_all d0psi", obm_debug
     !!!obm_debug

     !
     !    compute preconditioned residual vector and convergence check
     !
     lbnd = 0
     do ibnd = 1, nbnd
        if (conv (ibnd) .eq.0) then
           lbnd = lbnd+1
           call zcopy (ndmx*npol, g (1, ibnd), 1, h (1, ibnd), 1)
           call cg_psi(ndmx, ndim, 1, h(1,ibnd), h_diag(1,ibnd) )
           if (gamma_only) then
            rho(lbnd)=2.0d0*ddot(2*ndmx*npol,h(1,ibnd),1,g(1,ibnd),1) 
            if(gstart==2) rho(lbnd)=rho(lbnd)-dble(h(1,ibnd))*dble(g(1,ibnd))
           else
            rho(lbnd) = zdotc (ndmx*npol, h(1,ibnd), 1, g(1,ibnd), 1)
           endif
        endif
     enddo
     kter_eff = kter_eff + DBLE (lbnd) / DBLE (nbnd)
#ifdef __PARA
     call mp_sum(  rho(1:lbnd) , intra_pool_comm )
#endif
     do ibnd = nbnd, 1, -1
        if (conv(ibnd).eq.0) then
           rho(ibnd)=rho(lbnd)
           lbnd = lbnd -1
           anorm = sqrt (rho (ibnd) )
!           write(6,*) ibnd, anorm
           if (anorm.lt.ethr) conv (ibnd) = 1
          if (lr_verbosity > 5 ) & 
            write(stdout,'(5X,"lr_cgsolve_all: iter,ibnd,anorm,rho=",1X,i3,1X,i3,1X,e12.5,1X,e12.5)')&
             iter,ibnd,anorm,rho(ibnd) 
        endif
     enddo
!
     conv_root = .true.
     do ibnd = 1, nbnd
        conv_root = conv_root.and. (conv (ibnd) .eq.1)
     enddo
     if (conv_root) goto 100
     !
     !        compute the step direction h. Conjugate it to previous step
     !
     lbnd = 0
     do ibnd = 1, nbnd
        if (conv (ibnd) .eq.0) then
!
!          change sign to h 
!
           call dscal (2 * ndmx * npol, - 1.d0, h (1, ibnd), 1)
           if (iter.ne.1) then
              dcgamma = rho (ibnd) / rhoold (ibnd)
              call zaxpy (ndmx*npol, dcgamma, hold (1, ibnd), 1, h (1, ibnd), 1)
           endif

!
! here hold is used as auxiliary vector in order to efficiently compute t = A*h
! it is later set to the current (becoming old) value of h 
!
           lbnd = lbnd+1
           call zcopy (ndmx*npol, h (1, ibnd), 1, hold (1, lbnd), 1)
           eu (lbnd) = e (ibnd)
        endif
     enddo
     !
     !        compute t = A*h
     !
     call h_psi (ndim, hold, t, eu, ik, lbnd)
     !print *, hold(1:5,lbnd)
     !
     !        compute the coefficients a and c for the line minimization
     !        compute step length lambda
     lbnd=0
     do ibnd = 1, nbnd
        if (conv (ibnd) .eq.0) then
           lbnd=lbnd+1
           if (gamma_only) then
            a(lbnd) = 2.0d0*ddot(2*ndmx*npol,h(1,ibnd),1,g(1,ibnd),1)
            c(lbnd) = 2.0d0*ddot(2*ndmx*npol,h(1,ibnd),1,t(1,lbnd),1)
            if (gstart == 2) then
             a(lbnd)=a(lbnd)-dble(h(1,ibnd))*dble(g(1,ibnd))
             c(lbnd)=c(lbnd)-dble(h(1,ibnd))*dble(t(1,lbnd))
            endif
           else
            a(lbnd) = zdotc (ndmx*npol, h(1,ibnd), 1, g(1,ibnd), 1)
            c(lbnd) = zdotc (ndmx*npol, h(1,ibnd), 1, t(1,lbnd), 1)
           endif
        end if
     end do
#ifdef __PARA
     call mp_sum(  a(1:lbnd), intra_pool_comm )
     call mp_sum(  c(1:lbnd), intra_pool_comm )
#endif
     lbnd=0
     do ibnd = 1, nbnd
        if (conv (ibnd) .eq.0) then
           lbnd=lbnd+1
           dclambda = CMPLX( - a(lbnd) / c(lbnd), 0.d0)
           !
           !    move to new position
           !
           call zaxpy (ndmx*npol, dclambda, h(1,ibnd), 1, dpsi(1,ibnd), 1)
           !
           !    update to get the gradient
           !
           !g=g+lam
           call zaxpy (ndmx*npol, dclambda, t(1,lbnd), 1, g(1,ibnd), 1)
           !
           !    save current (now old) h and rho for later use
           ! 
           call zcopy (ndmx*npol, h(1,ibnd), 1, hold(1,ibnd), 1)
           rhoold (ibnd) = rho (ibnd)
        endif
     enddo
  enddo
100 continue
  kter = kter_eff
  deallocate (eu)
  deallocate (rho, rhoold)
  deallocate (conv)
  deallocate (a,c)
  deallocate (g, t, h, hold)

  call stop_clock ('cgsolve')
  return
end subroutine lr_cgsolve_all
