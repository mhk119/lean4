/*
Copyright (c) 2015 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.

Author: Leonardo de Moura
*/
#include "util/interrupt.h"
#include "library/blast/strategy.h"
#include "library/blast/choice_point.h"
#include "library/blast/blast.h"
#include "library/blast/proof_expr.h"
#include "library/blast/trace.h"

namespace lean {
namespace blast {
strategy_fn::strategy_fn() {}

action_result strategy_fn::activate_hypothesis() {
    auto hidx = curr_state().select_hypothesis_to_activate();
    if (!hidx) return action_result::failed();
    auto r    = hypothesis_pre_activation(*hidx);
    if (!solved(r) && !failed(r)) {
        curr_state().activate_hypothesis(*hidx);
        return hypothesis_post_activation(*hidx);
    } else {
        return r;
    }
}

action_result strategy_fn::next_branch(expr pr) {
    while (m_ps_check_point.has_new_proof_steps(curr_state())) {
        proof_step s     = curr_state().top_proof_step();
        action_result r  = s.resolve(unfold_hypotheses_ge(curr_state(), pr));
        switch (r.get_kind()) {
        case action_result::Failed:
            trace(">>> next-branch FAILED <<<");
            return r;
        case action_result::Solved:
            pr = r.get_proof();
            curr_state().pop_proof_step();
            break;
        case action_result::NewBranch:
            return action_result::new_branch();
        }
    }
    return action_result::solved(pr);
}

optional<expr> strategy_fn::search() {
    scope_choice_points scope1;
    m_ps_check_point          = curr_state().mk_proof_steps_check_point();
    m_init_num_choices        = get_num_choice_points();
    unsigned init_proof_depth = curr_state().get_proof_depth();
    unsigned max_depth        = get_config().m_max_depth;
    if (is_trace_enabled()) {
        ios().get_diagnostic_channel() << "* Search upto depth " << max_depth << "\n\n";
    }
    trace_curr_state();
    action_result r = next_action();
    trace_curr_state_if(r);
    while (true) {
        check_system("blast");
        lean_assert(curr_state().check_invariant());
        if (curr_state().get_proof_depth() > max_depth) {
            trace(">>> maximum search depth reached <<<");
            r = action_result::failed();
        }
        switch (r.get_kind()) {
        case action_result::Failed:
            r = next_choice_point(m_init_num_choices);
            if (failed(r)) {
                // all choice points failed...
                trace(">>> proof not found, no choice points left <<<");
                if (get_config().m_show_failure)
                    display_curr_state();
                return none_expr();
            }
            trace("* next choice point");
            break;
        case action_result::Solved:
            r = next_branch(r.get_proof());
            if (r.get_kind() == action_result::Solved) {
                // all branches have been solved
                trace("* found proof");
                return some_expr(unfold_hypotheses_ge(curr_state(), r.get_proof(), init_proof_depth));
            }
            trace("* next branch");
            break;
        case action_result::NewBranch:
            r = next_action();
            break;
        }
        trace_curr_state_if(r);
    }
}

strategy operator||(strategy const & s1, strategy const & s2) {
    return [=]() { // NOLINT
        if (auto r = s1())
            return r;
        else
            return s2();
    };
}
}}
